'use strict';
const crypto = require('node:crypto');
const os = require('node:os');
const path = require('node:path');

function deriveIdentity(ipcHook) {
  if (typeof ipcHook !== 'string' || ipcHook.length === 0) {
    throw new Error('VSCODE_IPC_HOOK_CLI is required for exact-window routing');
  }
  return crypto.createHash('sha256').update(ipcHook).digest('hex').slice(0, 24);
}

function pathsFor(ipcHook, options = {}) {
  const uid = options.uid ?? process.getuid();
  const tmpdir = options.tmpdir ?? os.tmpdir();
  const identity = deriveIdentity(ipcHook);
  const runtimeDir = path.join(tmpdir, `resume-claude-sessions-${uid}`);
  return {
    identity,
    runtimeDir,
    socketPath: path.join(runtimeDir, `bridge-${identity}.sock`),
    metadataPath: path.join(runtimeDir, `bridge-${identity}.json`),
  };
}

module.exports = { deriveIdentity, pathsFor };
