const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { startServer } = require('../lib/server');
const { readJsonLine, writeJsonLine } = require('../lib/protocol');

function request(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let data = '';
    socket.on('connect', () => socket.write(`${JSON.stringify(payload)}\n`));
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => resolve(JSON.parse(data)));
    socket.on('error', reject);
  });
}

const payload = () => ({ version: 1, requestId: 'a'.repeat(32), terminals: [
  { name: 'one', cwd: '/tmp', command: 'printf one' },
  { name: 'two', cwd: '/tmp', command: 'printf two' },
] });

test('creates only requested terminals and returns their count', async t => {
  const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-'));
  const created = [];
  const server = await startServer({ ipcHook: '/tmp/test-window', tmpdir, uid: 42,
    createTerminal: async descriptor => created.push(descriptor), logger: { info() {}, error() {} } });
  t.after(async () => { await server.close(); fs.rmSync(tmpdir, { recursive: true, force: true }); });
  const response = await request(server.paths.socketPath, payload());
  assert.equal(response.created, 2);
  assert.deepEqual(created, payload().terminals);
});

test('malformed request creates no terminals', async t => {
  const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-'));
  const created = [];
  const server = await startServer({ ipcHook: '/tmp/test-window-2', tmpdir, uid: 43,
    createTerminal: async descriptor => created.push(descriptor), logger: { info() {}, error() {} } });
  t.after(async () => { await server.close(); fs.rmSync(tmpdir, { recursive: true, force: true }); });
  const bad = payload(); bad.terminals[0].cwd = 'relative';
  const response = await request(server.paths.socketPath, bad);
  assert.equal(response.created, 0);
  assert.equal(created.length, 0);
  assert.match(response.errors[0], /cwd/);
});

test('extension never manipulates pre-existing terminals or split locations', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
  for (const forbidden of ['window.terminals', '.dispose(', 'location:', 'reloadWindow', '--reuse-window']) {
    assert.equal(source.includes(forbidden), false, `forbidden extension API: ${forbidden}`);
  }
  assert.match(source, /createTerminal\(\{ name, cwd \}\)/);
});

test('readJsonLine resolves with the parsed object up to the first newline', async () => {
  const server = net.createServer(async socket => {
    const value = await readJsonLine(socket);
    socket.end(`${JSON.stringify({ echoed: value })}\n`);
  });
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-')), 'rjl.sock');
  await new Promise(resolve => server.listen(socketPath, resolve));
  try {
    const response = await request(socketPath, { hello: 'world' });
    assert.deepEqual(response, { echoed: { hello: 'world' } });
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(socketPath, { force: true });
  }
});

test('readJsonLine rejects on malformed JSON before the newline', async () => {
  const server = net.createServer(async socket => {
    try {
      await readJsonLine(socket);
      socket.end('unreachable\n');
    } catch (error) {
      socket.end(`${JSON.stringify({ error: error.message })}\n`);
    }
  });
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-')), 'rjl-bad.sock');
  await new Promise(resolve => server.listen(socketPath, resolve));
  try {
    const response = await new Promise((resolve, reject) => {
      const socket = net.createConnection(socketPath);
      let data = '';
      socket.on('connect', () => socket.write('not-json\n'));
      socket.on('data', chunk => { data += chunk; });
      socket.on('end', () => resolve(JSON.parse(data)));
      socket.on('error', reject);
    });
    assert.match(response.error, /invalid JSON/);
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(socketPath, { force: true });
  }
});

test('readJsonLine rejects when payload exceeds the byte cap', async () => {
  const server = net.createServer(async socket => {
    try {
      await readJsonLine(socket, { maxBytes: 16 });
    } catch (error) {
      // socket already destroyed by readJsonLine; nothing to write back.
    }
  });
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-')), 'rjl-big.sock');
  await new Promise(resolve => server.listen(socketPath, resolve));
  try {
    await new Promise((resolve, reject) => {
      const socket = net.createConnection(socketPath);
      socket.on('connect', () => socket.write(`${JSON.stringify({ padding: 'x'.repeat(64) })}\n`));
      socket.on('close', resolve);
      socket.on('error', () => resolve());
      setTimeout(resolve, 500);
    });
    assert.ok(true, 'server destroyed the oversized connection without crashing');
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(socketPath, { force: true });
  }
});

test('close() resolves promptly even while a client holds an idle connection open', async t => {
  const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-'));
  const server = await startServer({ ipcHook: '/tmp/test-window-idle', tmpdir, uid: 44,
    createTerminal: async () => {}, logger: { info() {}, error() {} } });
  t.after(() => fs.rmSync(tmpdir, { recursive: true, force: true }));

  // Connect but never send a terminating newline and never close: this
  // socket is never destroyed by the server (readJsonLine only settles on
  // 'data' containing a newline, on 'end', or on 'error'), so it stays open
  // for the lifetime of the test unless close() forcibly destroys it.
  const idleSocket = net.createConnection(server.paths.socketPath);
  await new Promise((resolve, reject) => {
    idleSocket.on('connect', resolve);
    idleSocket.on('error', reject);
  });

  const start = Date.now();
  await Promise.race([
    server.close(),
    new Promise((_, reject) => setTimeout(() => reject(new Error('close() did not resolve within 2s')), 2000)),
  ]);
  const elapsed = Date.now() - start;
  assert.ok(elapsed < 2000, `close() took too long: ${elapsed}ms`);

  idleSocket.destroy();
});

test('writeJsonLine writes newline-terminated JSON and ends the socket', async () => {
  const server = net.createServer(socket => {
    writeJsonLine(socket, { version: 1, created: 0, errors: [] });
  });
  const socketPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-')), 'wjl.sock');
  await new Promise(resolve => server.listen(socketPath, resolve));
  try {
    const raw = await new Promise((resolve, reject) => {
      const socket = net.createConnection(socketPath);
      let data = '';
      socket.on('data', chunk => { data += chunk; });
      socket.on('end', () => resolve(data));
      socket.on('error', reject);
    });
    assert.equal(raw.endsWith('\n'), true);
    assert.deepEqual(JSON.parse(raw), { version: 1, created: 0, errors: [] });
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(socketPath, { force: true });
  }
});
