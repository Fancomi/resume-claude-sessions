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
