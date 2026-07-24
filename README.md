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
per-window 的本地 Unix socket 直接把要恢复的会话作为「集成终端」追加到**当前
调用它的这个窗口**里，不新开窗口、不 reload、不复用（`-r`）。只有桥接不可用
时才回退到固定用 `-n` 打开一个新窗口。

安装桥接扩展（不会 reload 任何窗口）：

```bash
./scripts/install-comate-bridge.sh
# No window is reloaded. Restart Comate naturally when convenient.

bash resume-claude-sessions.sh
```

行为总结：

- **桥接可用**：把每个选中的会话作为独立终端追加到当前调用窗口，当前窗口
  已有的终端、编辑器、其它窗口状态**一律不会被修改**。
- **桥接不可用**（扩展未安装/未激活/`VSCODE_IPC_HOOK_CLI` 缺失等）：回退到
  固定 `-n` 打开一个新窗口，根目录为 `penghaotian`（或 `RESUME_VSCODE_FOLDER`
  指定的目录），任务通过 `runOn: folderOpen` 自动并行启动；**绝不**使用
  `-r`/`--reuse-window`/reload 当前窗口。
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
