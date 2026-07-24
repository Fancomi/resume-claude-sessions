'use strict';
const path = require('node:path');
const fs = require('node:fs');
const MAX_BYTES = 1024 * 1024;
const MAX_TERMINALS = 100;

function plainString(value, field) {
  if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) {
    throw new Error(`${field} must be a non-empty string without NUL bytes`);
  }
  return value;
}

function validateRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('request must be an object');
  if (value.version !== 1) throw new Error('unsupported protocol version');
  if (!/^[a-f0-9]{32}$/.test(value.requestId || '')) throw new Error('invalid requestId');
  if (!Array.isArray(value.terminals) || value.terminals.length < 1 || value.terminals.length > MAX_TERMINALS) {
    throw new Error('terminals must contain 1 to 100 entries');
  }
  const terminals = value.terminals.map((terminal, index) => {
    const name = plainString(terminal.name, `terminals[${index}].name`);
    const cwd = plainString(terminal.cwd, `terminals[${index}].cwd`);
    const command = plainString(terminal.command, `terminals[${index}].command`);
    if (!path.isAbsolute(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error(`invalid cwd: ${cwd}`);
    return { name, cwd, command };
  });
  return { version: 1, requestId: value.requestId, terminals };
}

function readJsonLine(socket, options = {}) {
  const maxBytes = options.maxBytes ?? MAX_BYTES;
  return new Promise((resolve, reject) => {
    let bytes = 0; const chunks = [];
    socket.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > maxBytes) { reject(new Error('request exceeds 1 MiB')); socket.destroy(); return; }
      chunks.push(chunk);
      const data = Buffer.concat(chunks);
      const newline = data.indexOf(0x0a);
      if (newline !== -1) {
        socket.pause();
        try { resolve(JSON.parse(data.subarray(0, newline).toString('utf8'))); }
        catch (error) { reject(new Error(`invalid JSON: ${error.message}`)); }
      }
    });
    socket.on('end', () => reject(new Error('connection closed before newline')));
    socket.on('error', reject);
  });
}

function writeJsonLine(socket, value) { socket.end(`${JSON.stringify(value)}\n`); }
module.exports = { MAX_BYTES, MAX_TERMINALS, validateRequest, readJsonLine, writeJsonLine };
