const test = require('node:test');
const assert = require('node:assert/strict');
const { validateRequest } = require('../lib/protocol');

const valid = () => ({
  version: 1,
  requestId: '0123456789abcdef0123456789abcdef',
  terminals: [{ name: 'resume: demo', cwd: '/tmp', command: "printf '%s\\n' ok" }],
});

test('accepts a valid request', () => assert.deepEqual(validateRequest(valid()), valid()));
test('rejects unsupported versions', () => {
  const value = valid(); value.version = 2;
  assert.throws(() => validateRequest(value), /version/);
});
test('rejects invalid terminal data before creation', () => {
  for (const patch of [
    { cwd: 'relative' },
    { name: 'bad\0name' },
    { command: 'bad\0command' },
  ]) {
    const value = valid(); Object.assign(value.terminals[0], patch);
    assert.throws(() => validateRequest(value));
  }
});
test('rejects more than 100 terminals', () => {
  const value = valid(); value.terminals = Array.from({ length: 101 }, () => valid().terminals[0]);
  assert.throws(() => validateRequest(value), /100/);
});
