# Windows PowerShell 5.1+. Dot-source for setup and isolated tab launch functions.
[CmdletBinding()]
param(
    [string]$CacheRoot,
    [string]$Proxy,
    [switch]$Direct,
    [string]$ArchivePath,
    [switch]$Offline,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$script:WezTermSourceRoot = Split-Path -Parent $PSScriptRoot

function Get-WezTermSettings {
    Get-Content -LiteralPath (Join-Path $script:WezTermSourceRoot 'config\wezterm.json') -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Get-WezTermHome([string]$Override) {
    if (-not $Override) { $Override = $env:RESUME_WEZTERM_HOME }
    if (-not $Override) { $Override = Join-Path $env:LOCALAPPDATA 'resume-claude-sessions\wezterm' }
    [IO.Path]::GetFullPath($Override)
}

function Test-ResumeProxyPort {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect('127.0.0.1', 7890, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(200)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch { return $false }
    finally { $client.Dispose() }
}

function Set-ResumeProxyEnvironment {
    $selected = $env:RESUME_PROXY
    if (-not $selected -and -not $env:HTTPS_PROXY -and -not $env:HTTP_PROXY -and -not $env:ALL_PROXY -and (Test-ResumeProxyPort)) {
        $selected = 'http://127.0.0.1:7890'
    }
    if ($selected) {
        $env:HTTP_PROXY = $env:HTTPS_PROXY = $env:ALL_PROXY = $selected
    }
    if (-not $env:NO_PROXY) { $env:NO_PROXY = 'localhost,127.0.0.1,::1' }
}

function Get-WezTermDownloadRoutes([string]$DownloadProxy, [switch]$Direct) {
    if ($Direct) {
        [pscustomobject]@{ Name='直连'; Proxy='' }
        return
    }
    if ($DownloadProxy) {
        [pscustomobject]@{ Name='指定代理'; Proxy=$DownloadProxy }
        return
    }
    $seen = @{}
    foreach ($candidate in @($env:RESUME_PROXY, $env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY)) {
        if ($candidate -and -not $seen.ContainsKey($candidate)) {
            $seen[$candidate] = $true
            [pscustomobject]@{ Name='环境代理'; Proxy=$candidate }
        }
    }
    $localProxy = 'http://127.0.0.1:7890'
    if (-not $seen.ContainsKey($localProxy) -and (Test-ResumeProxyPort)) {
        [pscustomobject]@{ Name='本机 7890 代理'; Proxy=$localProxy }
    }
    [pscustomobject]@{ Name='直连'; Proxy='' }
}

function Invoke-WezTermDownload([string]$Url, [string]$Destination, $Route) {
    $arguments = @('--fail', '--location', '--silent', '--show-error', '--connect-timeout', '10',
        '--retry', '2', '--retry-delay', '1', '--retry-max-time', '90',
        '--max-time', '180', '--speed-limit', '1024', '--speed-time', '20', '--output', $Destination)
    if ($Route.Proxy) { $arguments += @('--proxy', $Route.Proxy) }
    else { $arguments += @('--noproxy', '*') }
    & (Join-Path $env:SystemRoot 'System32\curl.exe') @arguments $Url
    if ($LASTEXITCODE -ne 0) { throw ('下载失败（退出码 ' + $LASTEXITCODE + '）') }
}

function Get-CachedWezTerm([string]$HomePath) {
    $marker = Join-Path $HomePath 'current.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $null }
    $record = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.archive_sha256 -notmatch '^[0-9a-f]{64}$' -or
        $record.extract_dir -notmatch '^WezTerm-windows-[0-9]{8}-[0-9]{6}-[0-9a-f]+$') {
        throw 'WezTerm 缓存记录无效，请重新配置运行环境。'
    }
    if ($record.extract_dir.Substring('WezTerm-windows-'.Length, 8) -lt (Get-WezTermSettings).minimum_build) { return $null }
    $app = Join-Path (Join-Path $HomePath ('runtime\' + $record.archive_sha256)) $record.extract_dir
    $gui = Join-Path $app 'wezterm-gui.exe'
    $cli = Join-Path $app 'wezterm.exe'
    if (-not (Test-Path -LiteralPath $gui -PathType Leaf) -or -not (Test-Path -LiteralPath $cli -PathType Leaf) -or
        (Get-FileHash -LiteralPath $gui -Algorithm SHA256).Hash -ne $record.gui_sha256 -or
        (Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash -ne $record.cli_sha256) {
        throw 'WezTerm 缓存校验失败。关闭该终端后，用配置入口和原始 ZIP 重新配置。'
    }
    return $gui
}

function Get-ExistingWezTerm($Settings) {
    $command = Get-Command wezterm.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    $gui = Join-Path (Split-Path -Parent $command.Source) 'wezterm-gui.exe'
    if (-not (Test-Path -LiteralPath $gui -PathType Leaf)) { return $null }
    $version = (& $command.Source --version 2>$null) -join ' '
    if ($LASTEXITCODE -eq 0 -and $version -match '^wezterm ([0-9]{8})-[0-9]{6}-[0-9a-f]+') {
        if ($matches[1] -ge $Settings.minimum_build) { return $gui }
    }
    return $null
}

function Install-WezTermArchive([string]$ZipPath, [string]$ExpectedHash, [string]$HomePath, $Settings) {
    if ($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or
        (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw 'WezTerm ZIP 的 SHA-256 不匹配，未解压或执行。'
    }
    $hash = $ExpectedHash.ToLowerInvariant()
    $versionRoot = Join-Path $HomePath ('runtime\' + $hash)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $roots = @($zip.Entries | Where-Object { $_.FullName -match '^WezTerm-windows-[0-9]{8}-[0-9]{6}-[0-9a-f]+/wezterm-gui\.exe$' })
        if ($roots.Count -ne 1) { throw 'WezTerm ZIP 目录结构不符合预期。' }
        $extractDir = $roots[0].FullName.Split('/')[0]
        $build = $extractDir.Substring('WezTerm-windows-'.Length, 8)
        if ($build -lt $Settings.minimum_build) { throw '此 WezTerm 版本过旧，缺少 Windows 输入法修复。' }
        $boundary = [IO.Path]::GetFullPath($versionRoot).TrimEnd('\') + '\'
        foreach ($entry in $zip.Entries) {
            $resolved = [IO.Path]::GetFullPath((Join-Path $versionRoot $entry.FullName))
            if (-not $resolved.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'WezTerm ZIP 包含越界路径。'
            }
        }
    } finally { $zip.Dispose() }
    New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $versionRoot -Force
    $app = Join-Path $versionRoot $extractDir
    $gui = Join-Path $app 'wezterm-gui.exe'
    $cli = Join-Path $app 'wezterm.exe'
    if (-not (Test-Path -LiteralPath $gui -PathType Leaf) -or -not (Test-Path -LiteralPath $cli -PathType Leaf)) {
        throw 'WezTerm ZIP 缺少必要的可执行文件。'
    }
    $record = [ordered]@{
        archive_sha256=$hash
        extract_dir=$extractDir
        gui_sha256=(Get-FileHash -LiteralPath $gui -Algorithm SHA256).Hash.ToLowerInvariant()
        cli_sha256=(Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $marker = Join-Path $HomePath 'current.json'
    [IO.File]::WriteAllText($marker, (ConvertTo-Json $record), [Text.UTF8Encoding]::new($false))
    return $gui
}

function Install-WezTermPortable([string]$HomePath, [string]$DownloadProxy, [switch]$Direct, [string]$ArchivePath, [switch]$Offline) {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'WezTerm 需要 Windows x64。' }
    $HomePath = Get-WezTermHome $HomePath
    $settings = Get-WezTermSettings
    if ($ArchivePath) {
        $archive = (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).Path
        Write-Host '正在校验并安装已验证的离线包。'
        return Install-WezTermArchive -ZipPath $archive -ExpectedHash $settings.tested.sha256 -HomePath $HomePath -Settings $settings
    }
    $cached = Get-CachedWezTerm $HomePath
    if ($cached) { Write-Host '复用已校验的 WezTerm 共享缓存。'; return $cached }
    $existing = Get-ExistingWezTerm $settings
    if ($existing) { Write-Host '复用本机已有的兼容 WezTerm。'; return $existing }
    $archives = Join-Path $HomePath 'archives'
    $testedArchive = Join-Path $archives ($settings.tested.sha256 + '.zip')
    if (Test-Path -LiteralPath $testedArchive -PathType Leaf) {
        return Install-WezTermArchive -ZipPath $testedArchive -ExpectedHash $settings.tested.sha256 -HomePath $HomePath -Settings $settings
    }
    if ($Offline) { throw '没有可用的离线缓存，请运行“配置运行环境.bat”，或用 -ArchivePath 指定已验证 ZIP。' }
    New-Item -ItemType Directory -Path $archives -Force | Out-Null
    $lastFailure = ''
    foreach ($route in @(Get-WezTermDownloadRoutes -DownloadProxy $DownloadProxy -Direct:$Direct)) {
        Write-Host ('准备从官方 GitHub Releases 下载约 71 MB；连接方式：' + $route.Name)
        $token = [guid]::NewGuid().ToString('N')
        $checksumFile = Join-Path $archives ($token + '.sha256')
        $partial = Join-Path $archives ($token + '.partial.zip')
        try {
            Invoke-WezTermDownload -Url $settings.checksum_url -Destination $checksumFile -Route $route
            $checksum = [IO.File]::ReadAllText($checksumFile).Trim()
            if ($checksum -notmatch '^([0-9a-fA-F]{64})(?:\s|$)') { throw '官方 SHA-256 校验文件格式无效。' }
            $expected = $matches[1].ToLowerInvariant()
            $archive = Join-Path $archives ($expected + '.zip')
            if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
                (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
                Invoke-WezTermDownload -Url $settings.url -Destination $partial -Route $route
                if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $expected) {
                    throw '下载内容与官方 SHA-256 不一致，可能正值上游更新；请重新运行配置。'
                }
                Move-Item -LiteralPath $partial -Destination $archive -Force
            }
            return Install-WezTermArchive -ZipPath $archive -ExpectedHash $expected -HomePath $HomePath -Settings $settings
        } catch {
            $lastFailure = $_.Exception.Message
            Write-Host ($route.Name + ' 未完成：' + $lastFailure)
        }
    }
    throw ('无法下载 WezTerm。请检查 GitHub Releases 连接、使用 -Proxy 指定代理，或导入离线 ZIP。最后错误：' + $lastFailure)
}

function Start-CodexWezTerm($Groups) {
    $homePath = Get-WezTermHome
    $gui = Get-CachedWezTerm $homePath
    if (-not $gui) { $gui = Get-ExistingWezTerm (Get-WezTermSettings) }
    if (-not $gui) { throw 'WezTerm 尚未配置，请先运行“配置运行环境.bat”。' }
    $run = Join-Path $homePath ('runs\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    $planPath = Join-Path $run 'plan.json'
    $reportPath = Join-Path $run 'started.json'
    $plan = [ordered]@{ schema=1; groups=@($Groups); report=$reportPath }
    [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), [Text.UTF8Encoding]::new($false))
    $config = Join-Path $script:WezTermSourceRoot 'config\wezterm.lua'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $gui
    $info.UseShellExecute = $false
    $info.Arguments = '--config-file "' + $config + '" start --always-new-process --class ResumeCodexWezTerm'
    foreach ($name in @('WEZTERM_PANE','WEZTERM_UNIX_SOCKET','WEZTERM_CONFIG_FILE','WT_SESSION','WT_PROFILE_ID')) { $info.EnvironmentVariables.Remove($name) }
    $info.EnvironmentVariables['RESUME_WEZTERM_PLAN'] = $planPath
    $process = [Diagnostics.Process]::Start($info)
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    while (-not (Test-Path -LiteralPath $reportPath) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $reportPath)) {
        $detail = if ($process.HasExited) { '退出码：' + $process.ExitCode } else { '等待超时' }
        throw ('WezTerm 未确认标签页启动，' + $detail)
    }
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $report.ok) { throw ('WezTerm 启动失败：' + $report.error) }
    if ($report.groups.Count -ne @($Groups).Count) { throw 'WezTerm 窗口分组数量不匹配。' }
    for ($index=0; $index -lt @($Groups).Count; $index++) {
        if ($report.groups[$index].tab_count -ne $Groups[$index].tabs.Count) { throw 'WezTerm 标签页数量不匹配。' }
    }
    [IO.File]::WriteAllText((Join-Path $homePath 'last-run.json'), (ConvertTo-Json @{pid=$process.Id; report=$reportPath}), [Text.UTF8Encoding]::new($false))
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $homePath = Get-WezTermHome $CacheRoot
        if ($CheckOnly) {
            $gui = Get-CachedWezTerm $homePath
            if (-not $gui) { $gui = Get-ExistingWezTerm (Get-WezTermSettings) }
            if (-not $gui) { throw 'WezTerm 尚未配置，请先运行“配置运行环境.bat”。' }
        } else {
            $gui = Install-WezTermPortable -HomePath $homePath -DownloadProxy $Proxy -Direct:$Direct -ArchivePath $ArchivePath -Offline:$Offline
        }
        Write-Host ('WezTerm 已就绪：' + $gui)
        Write-Host ('共享缓存：' + $homePath)
        $candidates = if ($env:RESUME_CODEX_CMD) { @($env:RESUME_CODEX_CMD) } else { @('codex.exe','codex.cmd','codex.ps1','codex') }
        $codex = Get-Command $candidates -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $codex) { throw 'WezTerm 已准备完成；未检测到 Codex CLI，请先安装并登录 Codex 后再恢复会话。' }
        Write-Host 'Codex CLI 检查通过。现在可以运行“还原Codex会话.bat”。'
    } catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
