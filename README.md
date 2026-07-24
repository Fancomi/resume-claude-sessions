# resume-claude-sessions

一个跨平台的 **Claude Code 会话恢复启动器**。扫描 `~/.claude/projects` 下的所有会话，按日期分组、复选勾选，然后在终端 / GUI / tmux / VSCode 里批量恢复（`claude --resume <id>`）。

## 特性

- **按日期分组**，最近一组默认勾选，复选框交互（仿 Windows GUI）
- **自动识别运行环境**，无需手动指定：
  - **有图形界面**（macOS / Linux 桌面，且 python3+tkinter 可用）→ 弹出**真表格 GUI 窗口**（`ttk.Treeview`）
  - **无界面服务器**（Ubuntu / CentOS）→ **终端复选 TUI**（方向键移动、空格勾选，类似 Claude Code 选 skills）
  - **VSCode 远程**（检测到 `TERM_PROGRAM=vscode`）→ 生成 `.vscode/tasks.json`，`Ctrl/Cmd+Shift+B` 一键开面板
- **窗口合并控制**：相同「组」号的会话合并到一个终端窗口的多个标签页；每个会话可附加一个 `+CLI` 终端跑命令
- **打开方式自动适配**：macOS → Terminal.app 窗口+标签页；Linux 桌面 → gnome-terminal/konsole；无界面 → tmux；再不行顺序运行
- **零重型依赖**：只用各平台自带的 `bash` / `osascript` / `zenity` / `tmux` / `python3-tk`

## 文件

| 文件 | 说明 |
|---|---|
| `resume-claude-sessions.sh` | Linux / macOS 主脚本（自动识别环境） |
| `resume-gui.py` | GUI 表格选择器（tkinter，被 sh 自动调用） |
| `resume-claude-sessions.ps1` | Windows PowerShell 版（WinForms GUI） |
| `还原Claude会话.bat` | Windows 双击入口 |

## 使用

### macOS / Linux

```bash
./resume-claude-sessions.sh
```

有界面自动弹 GUI，无界面自动走终端复选。

**macOS 若要 GUI**，需要一个带可用 Tk 的 python3。系统自带的 Tk 常常过旧，建议：

```bash
brew install python-tk@3.14   # 版本号对应你的 homebrew python
```

**Ubuntu 桌面若要 GUI**：

```bash
sudo apt install python3-tk    # 或安装 zenity
```

### Windows

双击 `还原Claude会话.bat`，或：

```powershell
powershell -ExecutionPolicy Bypass -File resume-claude-sessions.ps1
```

## Comate 终端桥接（VSCode / Comate 远程）

在 Comate/VSCode 远程会话里，`resume-claude-sessions.sh` 会优先尝试通过一个
本地 Unix socket 直接把要恢复的会话作为「集成终端」追加到**当前窗口**里，不
新开窗口、不 reload、不复用（`-r`）。只有桥接不可用时才回退到固定用 `-n`
打开一个新窗口。

安装桥接扩展（不会 reload 任何窗口）：

```bash
./scripts/install-comate-bridge.sh
# No window is reloaded. Restart Comate naturally when convenient.

bash resume-claude-sessions.sh
```

### 用户确认的窗口配对（必须先手动确认一次）

隔离测试证明：同一个窗口里新建的终端所看到的 `VSCODE_IPC_HOOK_CLI` 值并**不**
稳定——同一窗口内不同终端的这个变量取值会不一样，所以它不能用来识别「当前
这个窗口」。因此正常启动路径**不再**依赖 `VSCODE_IPC_HOOK_CLI` 做路由，而是
改为一次性的、用户显式确认的「配对」：把当前**唯一存活**的桥接 socket 绑定
到扩展主机 PID 和期望的工作区根目录上。

在你确认当前只打开了一个 Comate/VSCode 窗口（因而只有一个存活的桥接
socket）之后，运行：

```bash
./scripts/pair-comate-bridge.sh --confirmed-current-window
```

该脚本只调用 `bridge/comate_bridge_client.py pair`，绝不调用
comate/code、绝不打开新窗口、绝不 reload/复用窗口、绝不创建终端。确认只对
**当前存活的扩展主机 PID** 有效：一旦该 PID 变化（例如 Comate 自然重启），
配对自动失效，需要重新运行本脚本确认一次。

正常启动时，`resume-claude-sessions.sh` 只会使用这个已确认的配对：如果配对
不存在、工作区不匹配、绑定的 PID 已经不是存活进程、绑定的 socket/身份发生了
变化，或者当前存活的桥接 socket 数量不是恰好一个（0 个或多个都算歧义），
则在发送任何请求之前就判定桥接不可用（退出码 2），直接回退到固定 `-n` 新
窗口，绝不猜测或尝试其它 socket。

行为总结：

- **桥接可用**（存在有效的已确认配对）：把每个选中的会话作为独立终端追加到
  已配对的窗口，该窗口已有的终端、编辑器、其它窗口状态**一律不会被修改**。
- **桥接不可用**（未运行过 `pair-comate-bridge.sh`、配对已失效、扩展未安装/
  未激活等）：回退到固定 `-n` 打开一个新窗口，根目录为 `penghaotian`（或
  `RESUME_VSCODE_FOLDER` 指定的目录），任务通过 `runOn: folderOpen` 自动并行
  启动；**绝不**使用 `-r`/`--reuse-window`/reload 当前窗口。
- 无论走哪条路径，**已存在的终端永远不会被读取、复用或关闭**——桥接只调用
  `vscode.window.createTerminal(...)` 新建终端，回退路径只写一个全新覆盖的
  `.code-workspace` 文件。
- `RESUME_SKIP_PERMISSIONS=1` 仍然是**显式 opt-in**：默认恢复会话时永远不带
  `--dangerously-skip-permissions`，只有显式设置该环境变量为 `1` 时才会加上。
- 生成的 `resume-sessions.code-workspace` 文件**每次运行都会被整体覆盖**，
  内容只包含窗口根目录和任务命令（会话 cwd、`claude --resume <id>` 命令），
  **不包含任何密钥**；已加入 `.gitignore`，不会被提交。

### 隔离集成测试

`scripts/test-comate-bridge-window.sh` 用于手工验证桥接在**全新窗口**里确实
可用，绝不会碰当前调用它的窗口：它记录并排除当前窗口的 socket 身份，只用
`comate -n <临时目录>` 打开一个新窗口，等待恰好一个新的桥接 socket 出现后
发送一次测试请求（两个独立终端），然后让新窗口保持打开供人工检查——**该脚本
不会自动关闭任何窗口**。

必须带上明确的确认标志才会运行：

```bash
./scripts/test-comate-bridge-window.sh --i-understand-this-opens-a-new-test-window
```

该脚本内部使用的显式 `--socket` 覆盖（配合 `--test-mode`，且路径必须位于当前
用户的私有运行时目录下）仅供这个隔离测试脚本使用，正常的
`resume-claude-sessions.sh` 启动流程永远不会暴露或使用这个覆盖参数。

## 环境变量（测试 / 覆盖）

| 变量 | 作用 |
|---|---|
| `RESUME_FORCE_SELECT=gui\|tui` | 强制选择界面类型 |
| `RESUME_FORCE_LAUNCH=terminal\|vscode\|tmux\|seq` | 强制打开方式 |
| `RESUME_PYBIN=/path/to/python` | 指定用于 GUI 的 python |
| `RESUME_AUTO_SELECT=1` | 不弹界面，直接用默认勾选 |
| `RESUME_DRY_RUN=1` | 只打印将要恢复的会话，不真正启动 |

## TUI 快捷键

`↑↓` / `jk` 移动 · `空格` 勾选 · `g` 改窗口组 · `c` 加 CLI · `a` 全选 · `n` 全不选 · `[` `]` 跳日期组 · `/` 搜索路径 · `回车` 确认 · `q` 退出

## GUI 操作

单击「开」列勾选 · 双击行切换勾选 · 双击「组」列改窗口组号 · 单击「+CLI」列 · 双击日期行切换整组 · 空格 / 回车 / Esc

## License

MIT
