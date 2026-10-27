# resume-claude-sessions

跨平台的 **Claude Code / Codex 会话恢复启动器**。扫描本地会话，按日期分组勾选，然后恢复（`claude --resume <id>` / `codex resume <id> --cd <目录>`）。

两个启动器共用同一套实现（`resume-sessions.sh`）：选择界面、命令引用、打印格式、终端/窗口启动规则完全一致，只有扫描来源、恢复命令和默认启动方式不同。`resume-claude-sessions.sh` 与 `resume-codex-sessions.sh` 只是保留原文件名的薄包装。

核心安全承诺：**永远不会重载、复用、替换或关闭你当前的编辑器窗口，也永远不会读取、复用或关闭任何已存在的终端。**

## 目录

- [快速开始](#快速开始)
- [默认行为](#默认行为)
- [选择界面](#选择界面)
- [启动方式](#启动方式)
  - [只打印命令，不启动](#只打印命令不启动)
  - [自动启动：RESUME_FORCE_LAUNCH=auto](#自动启动resume_force_launchauto)
- [Codex 会话](#codex-会话)
- [Comate / VSCode 终端桥接](#comate--vscode-终端桥接)
- [环境变量](#环境变量)
- [文件结构](#文件结构)
- [测试](#测试)
- [与旧版/上游的关系](#与旧版上游的关系)
- [已知约束](#已知约束)

## 快速开始

### macOS / Linux

Claude Code：

```bash
./resume-claude-sessions.sh
```

默认**只打印**每个会话的 `claude --resume <id>` 命令，由你自己粘贴到想用的终端里。想让脚本直接开终端/窗口：

```bash
RESUME_FORCE_LAUNCH=auto ./resume-claude-sessions.sh
```

Codex：

```bash
./resume-codex-sessions.sh
```

Codex 保留上游默认：自动识别环境并直接打开终端（同样可以用 `RESUME_FORCE_LAUNCH=print` 改成只打印）。

有图形界面自动弹 GUI，无界面自动走终端复选 TUI。macOS 若要 GUI，需要一个带可用 Tk 的 python3：

```bash
brew install python-tk@3.14   # 版本号对应你的 homebrew python
```

Ubuntu 桌面若要 GUI：

```bash
sudo apt install python3-tk
```

### Windows

Claude Code：双击 `还原Claude会话.bat`，或：

```powershell
powershell -ExecutionPolicy Bypass -File resume-claude-sessions.ps1
```

Codex：双击 `还原Codex会话.bat`，或：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\resume-codex-sessions.ps1
```

Windows 版是两套独立的 PowerShell/WinForms 实现，不依赖 Python。Claude 版会跳过命令行里已带 `--resume <id>` 的进程；Codex 版同理识别已打开的会话，优先使用 Windows Terminal，恢复时加 `--no-daemon`，BAT 入口还设置了 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`（本机地址绕过）。

### Comate / VSCode 远程（追加到当前窗口）

仅 Claude。一次性安装并确认配对，之后每次带 `RESUME_FORCE_LAUNCH=auto` 运行即可：

```bash
./scripts/install-comate-bridge.sh                      # 只安装扩展，不 reload 任何窗口
# 之后等 Comate 自然重启一次，扩展才会激活

./scripts/pair-comate-bridge.sh --confirmed-current-window   # 确认当前窗口
RESUME_FORCE_LAUNCH=auto bash resume-claude-sessions.sh      # 会话作为独立终端追加到该窗口
```

## 默认行为

| 启动器 | 默认 `RESUME_FORCE_LAUNCH` | 说明 |
|---|---|---|
| Claude | `print` | 只把命令打到 stdout，不启动任何东西 |
| Codex | `auto` | 按环境自动识别并真正打开终端/窗口 |

恢复时默认**不询问权限**（Claude / Codex、macOS / Linux / Windows 一致）：

- Claude 追加 `--dangerously-skip-permissions`；
- Codex 追加 `--dangerously-bypass-approvals-and-sandbox`。

需要保留权限确认时设 `RESUME_SKIP_PERMISSIONS=0`：Claude 去掉上述参数，Codex 不再附加任何 bypass 参数（回到 Codex 自己的默认策略）。Windows 版读取同一个环境变量。

## 选择界面

自动识别环境，无需手动指定：

| 环境 | 界面 |
|---|---|
| 有图形界面且 python3+tkinter 可用 | 真表格 GUI 窗口（`ttk.Treeview`） |
| 无界面服务器 / SSH | 终端复选 TUI |
| 非 TTY（管道、CI） | 纯文本编号输入 |

会话按日期分组，最近一组默认勾选。每行可控制：是否恢复、窗口组号（相同组号合并到同一窗口的多个标签页；print 模式下只决定打印顺序）、是否附加一个 `+CLI` 终端跑命令。

**TUI 快捷键**

`↑↓` / `jk` 移动 · `←` 折叠日期组 · `→` 展开 · `f` 下翻页 · `b` 上翻页 · `[` `]` 跳日期组 · `空格` 勾选（在日期行上则整组切换）· `g` 改窗口组号 · `c` 切换 `+CLI` · `a` 全选 · `n` 全不选 · `/` 搜索路径 · `回车` 确认 · `q` 退出

翻页用 `f`/`b`，因此不依赖键盘上的 PageUp/PageDown。

**GUI 操作**

单击「开」列勾选 · 双击行切换勾选 · 双击「组」列改窗口组号 · 单击「+CLI」列 · 双击日期行切换整组 · 空格 / 回车 / Esc

## 启动方式

`RESUME_FORCE_LAUNCH=auto` 时自动识别的行为，也可以直接点名其中一种：

| 环境 | `auto` 的行为 |
|---|---|
| macOS | Terminal.app：每组一个窗口，每会话一个标签页（标签页需要辅助功能权限，否则退化为窗口） |
| Linux 桌面 | gnome-terminal / konsole：每组一个窗口，每会话一个标签页；再退化到 xterm |
| Comate / VSCode | Claude：优先桥接追加到当前窗口；不可用时固定 `-n` 新开一个窗口。Codex：直接走固定 `-n` 新窗口 |
| 无界面 + tmux | 每组一个 tmux session，每会话一个 window |
| 都不可用 | 在当前终端顺序运行，退出一个继续下一个 |

### 只打印命令，不启动

Claude 的默认行为；Codex 用 `RESUME_FORCE_LAUNCH=print` 显式启用。

想让会话落在**已经开着的终端**里——这正是所有启动方式都做不到的事：VSCode/Comate 除了桥接之外没有办法把终端追加到现有窗口，而新窗口回退往往不是你要的；其它平台的启动方式也一律是新开窗口/标签页。所以这里干脆把"搬运"交给你自己：照常勾选，然后每个会话打印一条可直接粘贴的命令，脚本本身不启动任何东西。

```bash
./resume-claude-sessions.sh
```

输出每条两行——一行注释标明组号/会话/时间，一行命令；勾了 `+CLI` 的会话紧跟一条只 `cd` 的命令（你已经在 shell 里了，不需要 `exec`）：

```text
# G0  resume: project [08-12 20:42]
cd '/path/to/project' && claude --resume 3f2a…c1 --dangerously-skip-permissions

# G0  cli: project
cd '/path/to/project'
```

Codex 打印的是同一格式，命令为：

```text
cd '/path/to/work' && env CODEX_HOME=/home/me/.codex codex --dangerously-bypass-approvals-and-sandbox resume <id> --cd /path/to/work
```

`Gn` 组号照常生效，只是不再合并窗口，而是决定打印顺序——同一组的命令相邻，方便你把它们粘到同一个窗口的几个标签页里。

只有命令进 stdout，选择界面走 `/dev/tty`（没有控制终端时退到 stderr），所以重定向和管道都是干净的、无 ANSI 转义的：

```bash
./resume-claude-sessions.sh > cmds.txt
./resume-claude-sessions.sh | xclip -selection clipboard
```

与 `RESUME_DRY_RUN=1` 同时使用时 dry-run 优先，且其摘要会打到终端而非 stdout——dry-run 是调试开关，两者组合不是支持的用法。

### 自动启动：`RESUME_FORCE_LAUNCH=auto`

```bash
RESUME_FORCE_LAUNCH=auto ./resume-claude-sessions.sh
./resume-codex-sessions.sh                # Codex 默认就是 auto
```

`auto` 按上表自动识别环境（VSCode 桥接 / Terminal.app / gnome-terminal / tmux / 顺序执行）。也可以直接点名某一种，例如 `RESUME_FORCE_LAUNCH=tmux`。

## Codex 会话

Codex 版扫描 `$CODEX_HOME/sessions`（默认 `~/.codex/sessions`）下的 `rollout-*.jsonl`，从 `session_meta.payload` 读取会话 ID 和工作目录，用 `codex resume <id> --cd <目录>` 恢复。

- 会话按日志最后修改日期分组，默认勾选最近日期；
- 组 `0`（Windows 也可留空）= 独立窗口；其余正整数分组 = 一个窗口多个标签页；
- 工作目录不存在、损坏日志和子代理会话默认跳过（`RESUME_INCLUDE_SUBAGENTS=1` 可包含子代理）；
- 同一 ID 有多份 rollout 时取最新的一份；
- 恢复命令默认带 `--dangerously-bypass-approvals-and-sandbox`，并显式设置 `CODEX_HOME`，避免复用旧环境变量；
- 归档会话不在扫描范围内。

不启动终端的检查方式：

```bash
RESUME_CODEX_HOME=/path/to/codex RESUME_AUTO_SELECT=1 RESUME_DRY_RUN=1 bash ./resume-codex-sessions.sh
```

Windows 还支持：

```powershell
.\resume-codex-sessions.ps1 -AutoSelect -DryRun
.\resume-codex-sessions.ps1 -List          # JSON 会话清单
.\resume-codex-sessions.ps1 -CodexHome 'D:\CodexData' -AutoSelect -DryRun
```

## Comate / VSCode 终端桥接

**仅 Claude。** 桥接协议目前只组合 `claude --resume <id>`；Codex 在 VSCode 中使用固定的新窗口回退。

### 为什么需要桥接

Comate/VSCode 的 CLI 没有「向已打开的窗口创建集成终端并注入命令」的接口（`comate --help` 只有 `-n`/`-r`/`-a`/`-g`，且 `--open-url` 明确不支持）。要自动并行拉起多个终端，只能靠扩展 API 或 `runOn: folderOpen` 任务。因此本项目提供一个本地扩展作为桥接。

### 架构

| 组件 | 职责 |
|---|---|
| `comate-bridge/` | 本地 Comate 扩展：启动时在私有目录建立一个 Unix socket，校验请求后调用 `vscode.window.createTerminal()` |
| `bridge/comate_bridge_client.py` | Python 客户端：窗口配对、协议编码、有界超时传输、响应校验 |
| `resume-sessions.sh` | `RESUME_FORCE_LAUNCH=auto`（或 `=vscode`）时 Claude 优先走桥接，不可用时回退固定 `-n` 新窗口 |

每个会话创建的都是**独立的顶层终端**（不传 `location`，不设 `presentation.group`），不是拆分/子终端。扩展绝不枚举、关闭、隐藏、重命名、复用已有终端，也不向已有终端发送任何文本。

### 用户确认的窗口配对（必须先手动确认一次）

隔离测试推翻了最初的设计假设：`VSCODE_IPC_HOOK_CLI` 更接近**终端级**标识，同一窗口内新建的终端会看到不同取值，因此不能用来识别「当前这个窗口」。正常启动路径**不再**依赖它做路由。

改为一次性、用户显式确认的配对：把当前**唯一存活**的桥接 socket 绑定到扩展主机 PID 和期望的工作区根目录。

在确认当前只打开了一个 Comate/VSCode 窗口（因而只有一个存活桥接 socket）后运行：

```bash
./scripts/pair-comate-bridge.sh --confirmed-current-window
```

该脚本只调用 `bridge/comate_bridge_client.py pair`，绝不调用 comate/code、绝不打开新窗口、绝不 reload/复用窗口、绝不创建终端。

配对记录写在 `/tmp/resume-claude-sessions-$UID/paired-window.json`（权限 `0600`，位于权限 `0700` 的私有运行时目录内），绑定四项：socket 身份、socket 路径、扩展主机 PID、工作区根目录。写入使用临时文件加 `os.replace`，避免读到半成品。

### 运行时行为

以下均指走到了 VSCode 启动路径时（`RESUME_FORCE_LAUNCH=auto` 在 Comate/VSCode 环境中，或显式 `=vscode`）；默认的 `print` 不会碰桥接。

**桥接可用**（存在有效的已确认配对）：把每个选中的会话作为独立终端追加到已配对窗口。该窗口已有的终端、编辑器和其它窗口状态一律不变。

**桥接不可用**：在发送任何字节之前就判定为不可用（退出码 2），回退到固定 `-n` 打开一个新窗口，根目录为当前目录（或 `RESUME_VSCODE_FOLDER`），任务通过 `runOn: folderOpen` 自动并行启动。以下情形都算不可用，一律 fail closed，绝不猜测其它 socket：

- 没运行过 `pair-comate-bridge.sh`，或配对文件损坏 / 版本不符
- 工作区根目录与配对记录不一致
- 绑定的 PID 已不是存活进程（例如 Comate 重启）
- 绑定的 socket 路径或身份发生变化，或元数据权限/版本/身份校验失败
- 当前存活的桥接 socket 数量不是恰好一个（0 个或多个都算歧义）

**发送之后不再回退**：一旦请求字节可能已经送达，客户端绝不重发，脚本也绝不新开窗口，以免产生重复终端。

| 退出码 | 含义 | 脚本动作 |
|---|---|---|
| 0 | 桥接成功 | 结束 |
| 2 | 发送前即判定不可用 | 回退固定 `-n` 新窗口 |
| 3 | 投递状态不确定 | 不回退，报错退出 |
| 4 | 桥接报告了终端创建错误 | 不回退，报错退出 |
| 其它 | 客户端内部错误 | 不回退，报错退出 |

### 协议与限制

请求为一行 JSON，回复亦为一行 JSON。限制：单请求 ≤ 1 MiB；单请求 ≤ 100 个终端；`cwd` 必须是存在的绝对目录；`name`/`cwd`/`command` 必须是不含 NUL 的字符串；连接与读取超时有界；版本不符视为桥接失败。命令通过 `shlex.join` 安全引用，shell 侧只传 NUL 分隔记录，不手工拼 JSON。

### 安装

```bash
./scripts/install-comate-bridge.sh
```

只执行 `--install-extension <vsix> --force`，绝不执行 `-n`、`-r`、`--reuse-window`、reload 或替换工作区。安装完成后扩展要等你**下一次自然重启 Comate** 才会激活；在那之前脚本会走安全的新窗口回退。

VSIX 由 `scripts/package-comate-bridge.py` 用标准库确定性打包（固定时间戳、排序条目、闭合白名单），不包含测试、socket、元数据或用户设置；产物在 `dist/`，已忽略不提交。

### 隔离集成测试

`scripts/test-comate-bridge-window.sh` 用于在**全新窗口**里验证桥接，绝不碰当前调用它的窗口：先记录并排除当前窗口的 socket 身份，只用 `comate -n <临时目录>` 打开一个新窗口，等待恰好出现一个新桥接 socket，发送一次测试请求创建两个无害终端，自动比对终端上报的 IPC 哈希与目标 socket 身份，然后让新窗口保持打开供人工检查。**该脚本不会关闭任何窗口，无论校验结果如何。**

必须带明确确认标志：

```bash
./scripts/test-comate-bridge-window.sh --i-understand-this-opens-a-new-test-window
```

脚本内部使用的 `--socket` 覆盖需同时带 `--test-mode`，且路径必须位于当前用户的私有运行时目录下；测试专用的 `test` 记录类型默认被拒绝，只有 `send-input0 --test-mode` 才可能构造。正常启动流程永远不会传这些参数，也无法触达这些能力。

## 环境变量

### 共用

| 变量 | 作用 |
|---|---|
| `RESUME_PROVIDER=claude\|codex` | 选择扫描来源；两个包装脚本会自动设置 |
| `RESUME_SKIP_PERMISSIONS=0` | 关闭默认的免确认模式（默认 `1`） |
| `RESUME_FORCE_SELECT=gui\|tui` | 强制选择界面类型 |
| `RESUME_FORCE_LAUNCH=print\|auto\|terminal\|vscode\|tmux\|seq` | 启动方式；Claude 默认 `print`，Codex 默认 `auto` |
| `RESUME_PYBIN=/path/to/python` | 指定 Python（GUI、Codex 元数据读取） |
| `RESUME_AUTO_SELECT=1` | 不弹界面，直接用默认勾选 |
| `RESUME_DRY_RUN=1` | 只打印将要恢复的会话，不真正启动 |
| `RESUME_VSCODE_FOLDER=<dir>` | 配对校验与新窗口回退使用的工作区根目录 |
| `BRIDGE_TEST_POLL_SECONDS=<n>` | 隔离测试等待新 socket 的秒数（默认 20） |
| `BRIDGE_TEST_IPC_POLL_SECONDS=<n>` | 隔离测试等待终端上报 IPC 的秒数（默认 20） |

### Claude

| 变量 | 作用 |
|---|---|
| `RESUME_PROJECTS_ROOT=<dir>` | 会话扫描根目录（默认 `~/.claude/projects`） |

### Codex

| 变量 | 作用 |
|---|---|
| `CODEX_HOME` | Codex 数据目录，默认 `~/.codex` |
| `RESUME_CODEX_HOME` | 优先于 `CODEX_HOME` 的数据目录覆盖；子进程使用同一目录 |
| `RESUME_CODEX_CMD` | 指定 Codex 可执行文件或脚本路径 |
| `RESUME_INCLUDE_SUBAGENTS=1` | 包含子代理会话 |

## 文件结构

| 路径 | 说明 |
|---|---|
| `resume-sessions.sh` | 共用引擎：扫描调度、选择界面、打印、终端/窗口/桥接启动 |
| `resume-claude-sessions.sh` | Claude 入口（`RESUME_PROVIDER=claude` 的薄包装） |
| `resume-codex-sessions.sh` | Codex 入口（`RESUME_PROVIDER=codex` 的薄包装） |
| `codex_sessions.py` | Codex rollout 元数据读取器（只读，不修改会话文件） |
| `resume-gui.py` | GUI 表格选择器（tkinter，被引擎自动调用） |
| `resume-claude-sessions.ps1` · `还原Claude会话.bat` | Windows Claude 版（WinForms GUI） |
| `resume-codex-sessions.ps1` · `还原Codex会话.bat` | Windows Codex 版（WinForms + Windows Terminal） |
| `comate-bridge/` | Comate 桥接扩展：`extension.js` 与 `lib/{identity,protocol,server}.js` |
| `bridge/comate_bridge_client.py` | Python 桥接客户端与 CLI |
| `scripts/package-comate-bridge.py` | 确定性 VSIX 打包 |
| `scripts/install-comate-bridge.sh` | 只安装、不 reload 的安装器 |
| `scripts/pair-comate-bridge.sh` | 一次性窗口确认配对 |
| `scripts/test-comate-bridge-window.sh` | 带守卫的隔离新窗口集成测试 |
| `tests/` | Python 单元与子进程测试 |

## 测试

```bash
npm --prefix comate-bridge test          # 15 个 Node 测试
python3 -m unittest discover -s tests    # 122 个 Python 测试
bash -n resume-sessions.sh resume-claude-sessions.sh resume-codex-sessions.sh scripts/*.sh
```

全部为离线测试：使用临时假 socket、假 CLI、假 `CODEX_HOME` 与源码断言，不会调用真实 Comate/Codex/Claude、不安装扩展、不打开或关闭窗口。源码断言会检查代码里不存在 `-r`、`--reuse-window`、reload 命令，以及任何操作已有终端的调用。

## 与旧版/上游的关系

- **一个实现**：`resume-claude-sessions.sh` / `resume-codex-sessions.sh` 的名字和用法不变，但都只转调 `resume-sessions.sh`；选择界面、引用与打印逻辑不会再各自演化。
- **合并了上游 Codex 版的功能**：Codex 扫描/恢复、`codex_sessions.py`、Windows Codex 入口与 GUI 的标题/提示覆盖。
- **合并了双方各自更好的实现**：上游的 AppleScript argv 传参（目录名含引号也不会破坏脚本）、konsole 多标签启动、tmux 按 window id 定位、非 TTY 输入去除 CR；旧版的 print 默认、桥接、`shquote`、折叠/翻页。
- **默认值对齐**：Claude/Codex、macOS/Linux/Windows 恢复时都默认免确认（`RESUME_SKIP_PERMISSIONS` 默认 `1`）；Claude 仍默认 `print`，Codex 仍默认 `auto`。
- **macOS bash 3.2 兼容**：修复了 `${x//\'/…}` 在系统自带 bash 下的错误引用，以及变量名后紧跟中文标点被误解析的问题；测试 fixture 也不再受 AF_UNIX 104 字节路径上限影响。

## 已知约束

- **Comate 重启后需重新配对**：扩展主机 PID 变化会让配对自动失效，重新运行一次 `./scripts/pair-comate-bridge.sh --confirmed-current-window` 即可。
- **同时打开第二个带桥接的窗口会暂时禁用配对快路径**：存活 socket 不唯一即视为歧义，按设计 fail closed，此时走新窗口回退。
- **PID 复用**：存活性用信号 0 检测，只能证明该 PID 存在，理论上存在 PID 复用的窄窗口；任一其它绑定字段不符仍会拒绝。
- **生成的 `resume-sessions.code-workspace` 每次运行整体覆盖**，只含窗口根目录与任务命令（会话 cwd、恢复命令），不含密钥；已忽略不提交。Claude 与 Codex 共用该文件名。
- **Codex 不支持桥接**：VSCode 中 Codex 固定走新窗口回退；桥接协议只接受 Claude 的 `--resume` 记录。
- 会话 ID 会像原有启动器那样出现在进程命令行中。
- 默认免确认意味着恢复的会话可以直接执行命令；在不受信任的仓库里请设置 `RESUME_SKIP_PERMISSIONS=0`。

## License

MIT
