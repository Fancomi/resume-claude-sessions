'use strict';
const fs = require('node:fs');
const net = require('node:net');
const { pathsFor } = require('./identity');
const { validateRequest, readJsonLine, writeJsonLine } = require('./protocol');

function isStaleSocket(socketPath) {
  return new Promise(resolve => {
    const probe = net.createConnection(socketPath);
    probe.on('connect', () => { probe.destroy(); resolve(false); });
    probe.on('error', () => resolve(true));
  });
}

async function startServer({ ipcHook, createTerminal, logger, tmpdir, uid }) {
  const paths = pathsFor(ipcHook, { tmpdir, uid });
  fs.mkdirSync(paths.runtimeDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(paths.runtimeDir, 0o700);

  if (fs.existsSync(paths.socketPath)) {
    const stale = await isStaleSocket(paths.socketPath);
    if (stale) fs.rmSync(paths.socketPath, { force: true });
    else throw new Error(`bridge already running for this window: ${paths.socketPath}`);
  }

  const metadata = { version: 1, pid: process.pid, identity: paths.identity, ipcHookHash: paths.identity };
  fs.writeFileSync(paths.metadataPath, `${JSON.stringify(metadata)}\n`, { mode: 0o600 });
  fs.chmodSync(paths.metadataPath, 0o600);

  const server = net.createServer(socket => {
    handleConnection(socket, createTerminal, logger).catch(error => {
      logger.error(`[resume-bridge] connection handler failed: ${error.message}`);
    });
  });
  server.on('error', error => logger.error(`[resume-bridge] server error: ${error.message}`));

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(paths.socketPath, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
  fs.chmodSync(paths.socketPath, 0o600);

  async function close() {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(paths.socketPath, { force: true });
    fs.rmSync(paths.metadataPath, { force: true });
  }

  return { close, paths };
}

async function handleConnection(socket, createTerminal, logger) {
  let raw;
  try {
    raw = await readJsonLine(socket);
  } catch (error) {
    writeJsonLine(socket, { version: 1, requestId: null, created: 0, errors: [error.message] });
    return;
  }

  let request;
  try {
    request = validateRequest(raw);
  } catch (error) {
    writeJsonLine(socket, {
      version: 1,
      requestId: /^[a-f0-9]{32}$/.test(raw?.requestId || '') ? raw.requestId : null,
      created: 0,
      errors: [error.message],
    });
    return;
  }

  let created = 0;
  const errors = [];
  for (const terminal of request.terminals) {
    try {
      await createTerminal(terminal);
      created += 1;
    } catch (error) {
      errors.push(`${terminal.name}: ${error.message}`);
      logger.error(`[resume-bridge] failed to create terminal ${terminal.name}: ${error.message}`);
    }
  }
  writeJsonLine(socket, { version: 1, requestId: request.requestId, created, errors });
}

module.exports = { startServer };
