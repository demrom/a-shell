// Exercise the real page and WASI worker scripts with a delayed WebKit reply.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');
const vm = require('node:vm');

const [resources, fixture, source = path.resolve(__dirname, '../..'), expectedStatus = '0'] = process.argv.slice(2);
assert.ok(resources && fixture, 'Usage: node webview-mailbox.cjs APP_BUNDLE GUEST_WASM [SCRIPTS_DIR [EXIT_STATUS]]');
const bundleRequire = createRequire(path.resolve(resources, 'wasm_worker_wasm.js'));
const executeScript = (context, name) => vm.runInContext(fs.readFileSync(path.join(source, name), 'utf8'), context);

let worker;
let terminal;
const calls = [];
const page = vm.createContext({
    Tarp: { require() {} },
    require: bundleRequire,
    TextEncoder,
    Worker: class {
        constructor() { worker = this; }
        postMessage(args) { this.args = args; }
    },
    prompt(message) {
        if (message.startsWith('libc\ncommandTerminated\n')) {
            const [, , status, ...diagnostic] = message.split('\n');
            terminal = { status: Number(status), diagnostic: diagnostic.join('\n') };
            return '';
        }
        const prefix = 'ashell-process\n';
        assert.ok(message.startsWith(prefix), message);
        const request = JSON.parse(message.slice(prefix.length));
        calls.push(request);
        return request.op === 'spawn' ? '0 23' : '23 1792';
    },
});
executeScript(page, 'wasm_withWorker.js');
page.executeWebAssembly(fs.readFileSync(fixture).toString('base64'), ['probe'], '/tmp', 0, { PATH: '/bin' });

const guest = vm.createContext({
    WebAssembly,
    TextDecoder,
    TextEncoder,
    btoa,
    importScripts() {},
    Tarp: { require() {} },
    require: bundleRequire,
    self: {},
    postMessage(data) {
        worker.onmessage({ data });
        if (data[1]?.startsWith?.('ashell-process\n')) {
            // Model a late WebKit completion writing to the legacy response slot.
            const legacy = worker.args[5];
            const bytes = new TextEncoder().encode('late');
            new Uint8Array(legacy, 4, bytes.length).set(bytes);
            Atomics.store(new Int32Array(legacy), 0, bytes.length + 1);
        }
    },
});
executeScript(guest, 'wasm_worker_wasm.js');
guest.onmessage({ data: worker.args });

assert.deepEqual(terminal, { status: Number(expectedStatus), diagnostic: '' }, 'guest result after a late legacy reply');
assert.deepEqual(calls.map(request => request.op), ['spawn', 'wait']);
assert.equal(calls[1].child, 23);
console.log('spawn and wait used a mailbox isolated from legacy I/O');
