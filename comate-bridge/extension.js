'use strict';
const vscode = require('vscode');
const { startServer } = require('./lib/server');
let bridge;

async function activate(context) {
  const ipcHook = process.env.VSCODE_IPC_HOOK_CLI;
  if (!ipcHook) {
    console.error('[resume-bridge] exact-window identity unavailable; bridge disabled');
    return;
  }
  bridge = await startServer({
    ipcHook,
    createTerminal: async ({ name, cwd, command }) => {
      const terminal = vscode.window.createTerminal({ name, cwd });
      terminal.sendText(command, true);
      terminal.show(false);
    },
    logger: console,
  });
  context.subscriptions.push({ dispose: () => bridge?.close() });
}

async function deactivate() { if (bridge) await bridge.close(); }
module.exports = { activate, deactivate };
