// Exercise the browser guest with real Wasmer; replace only the external WebKit prompt.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');
const vm = require('node:vm');

const [resources, fixture, mode = 'pipe', scripts = path.resolve(__dirname, '../..')] = process.argv.slice(2);
assert.ok(resources && fixture && ['pipe', 'popen', 'table', 'errors', 'fork-exec-rejected'].includes(mode), 'Usage: node webview-fd.cjs RESOURCES GUEST_WASM [pipe|popen|table|errors|fork-exec-rejected [SCRIPTS_DIR]]');
const requireBundle = createRequire(path.resolve(resources, 'wasm_worker_wasm.js'));
const load = (context, name) => vm.runInContext(fs.readFileSync(path.join(scripts, name), 'utf8'), context);
const calls = [];
let worker, terminal;
let bytes = Buffer.alloc(0);
const open = new Set();
const stdout = [];
const page = vm.createContext({
    Tarp: { require() {} },
    require: requireBundle,
    TextEncoder,
    Worker: class {
        constructor() { worker = this; }
        postMessage(args) { this.args = args; }
    },
    prompt(message) {
        const prefix = 'ashell-process\n';
        if (!message.startsWith(prefix)) {
            const [kind, op, value, payload, length, ...rest] = message.split('\n');
            assert.equal(kind, 'libc');
            if (op === 'commandTerminated') {
                terminal = { status: Number(value), diagnostic: [payload, length, ...rest].filter(v => v !== undefined).join('\n') };
                return '';
            }
            if (mode === 'table') {
                if (op === 'open') {
                    assert.match(value, /(^|\/)fixture$/);
                    return '91';
                }
                if (op === 'fstat') {
                    assert.equal(value, '91');
                    return 'stat(st_mode: 33188)';
                }
                if (op === 'close') {
                    assert.ok(value === '0' || value === '91');
                    return '0';
                }
            }
            assert.equal(op, 'write');
            assert.equal(value, '1');
            stdout.push(...payload.split(',').map(Number));
            return length;
        }
        const request = JSON.parse(message.slice(prefix.length));
        assert.equal(request.generation, '19');
        calls.push(request.op);
        switch (request.op) {
        case 'pipe':
            if (mode === 'errors' && calls.length === 1) {
                open.add(104);
                return '0 104 malformed';
            }
            open.add(100);
            open.add(101);
            return '0 100 101';
        case 'dup': {
            const source = mode === 'errors' ? 100 : 101;
            assert.equal(request.fd, source);
            assert.ok(open.has(source));
            open.add(102);
            return '0 102';
        }
        case 'write':
            assert.equal(request.fd, 102);
            assert.ok(open.has(102) && !open.has(101));
            bytes = Buffer.from(request.data, 'base64');
            return `0 ${bytes.length}`;
        case 'spawn':
            if (mode === 'fork-exec-rejected') {
                assert.equal(request.path, '');
                assert.deepEqual(request.argv, ['']);
                return '-28 0'; // EINVAL; the broker rejects an empty executable name.
            }
            assert.equal(mode, 'popen');
            assert.deepEqual(request.streams, [0, 101, 2]);
            assert.equal(request.path, 'dash');
            assert.ok(open.has(100) && open.has(101));
            bytes = Buffer.from('process-popen-ok\n');
            return '0 23';
        case 'wait':
            assert.equal(mode, 'popen');
            assert.equal(request.child, 23);
            assert.equal(open.size, 0);
            return '23 1792';
        case 'read': {
            assert.equal(request.fd, 100);
            assert.ok(open.has(100) && !open.has(102));
            const chunk = bytes.subarray(0, request.length);
            bytes = bytes.subarray(chunk.length);
            return chunk.length ? `0 ${chunk.length} ${chunk.toString('base64')}` : '0 0';
        }
        case 'close':
            if (!open.delete(request.fd)) {
                assert.equal(mode, 'errors');
                return '-8 0';
            }
            return mode === 'errors' && request.fd === 101 ? '-29 0' : '0 0';
        default:
            assert.fail(`Unexpected process request: ${request.op}`);
        }
    },
});
load(page, 'wasm_withWorker.js');
page.ashellProcessGeneration = '19';
page.executeWebAssembly(fs.readFileSync(fixture).toString('base64'), ['pipe'], '/tmp', 0, { PATH: '/bin' });
const guest = vm.createContext({
    ArrayBuffer, WebAssembly, TextDecoder, TextEncoder, btoa,
    importScripts() {},
    Tarp: { require() {} },
    require: requireBundle,
    self: {},
    postMessage(data) { worker.onmessage({ data }); },
});
load(guest, 'wasm_worker_wasm.js');
// Node loads Wasmer's CommonJS module outside the worker VM; WebKit loads it inside.
globalThis.prompt = guest.prompt;
try {
    guest.onmessage({ data: worker.args });
} finally {
    delete globalThis.prompt;
}
assert.deepEqual(terminal, { status: 0, diagnostic: '' });
const expected = {
    pipe: ['process-pipe-ok\n', ['pipe', 'dup', 'close', 'write', 'close', 'read', 'read', 'close']],
    popen: ['process-popen-ok\n', ['pipe', 'spawn', 'close', 'read', 'read', 'close', 'wait']],
    table: ['process-fd-table-ok\n', ['pipe', 'dup', 'close', 'close', 'close']],
    errors: ['process-fd-errors-ok\n', ['pipe', 'close', 'pipe', 'close', 'dup', 'close', 'close']],
    'fork-exec-rejected': ['process-fork-exec-rejected\n', ['spawn']],
};
assert.equal(Buffer.from(stdout).toString(), expected[mode][0]);
assert.deepEqual(calls, expected[mode][1]);
assert.equal(open.size, 0);
console.log(`Wasmer ${mode} passed`);
