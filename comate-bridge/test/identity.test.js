const test = require('node:test');
const assert = require('node:assert/strict');
const { deriveIdentity, pathsFor } = require('../lib/identity');

test('identity is deterministic and window-specific', () => {
  assert.equal(deriveIdentity('/tmp/vscode-ipc-a.sock'), deriveIdentity('/tmp/vscode-ipc-a.sock'));
  assert.notEqual(deriveIdentity('/tmp/vscode-ipc-a.sock'), deriveIdentity('/tmp/vscode-ipc-b.sock'));
  assert.match(deriveIdentity('/tmp/vscode-ipc-a.sock'), /^[a-f0-9]{24}$/);
});

test('socket path is private, short, and uid-scoped', () => {
  const paths = pathsFor('/tmp/vscode-ipc-a.sock', { uid: 1234, tmpdir: '/tmp' });
  assert.equal(paths.runtimeDir, '/tmp/resume-claude-sessions-1234');
  assert.equal(paths.socketPath, `${paths.runtimeDir}/bridge-${paths.identity}.sock`);
  assert.ok(Buffer.byteLength(paths.socketPath) < 108);
});

test('missing window identity is rejected', () => {
  assert.throws(() => deriveIdentity(''), /VSCODE_IPC_HOOK_CLI/);
});
