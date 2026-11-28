// Run the public guest with Preview 1 and a broker whose PEEK fails.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { WASI } = require('node:wasi');

const wasi = new WASI({ version: 'preview1', returnOnExit: true });
let peeks = 0;
let done = false;
const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[2])), {
    wasi_snapshot_preview1: wasi.wasiImport,
    ashell_v1: {
        process_spawn(_path, _pathLength, _argv, _argc, _env, _envc, _actions, _count, _flags, childOut) {
            new DataView(instance.exports.memory.buffer).setInt32(childOut, 23, true);
            return 0;
        },
        process_wait(pid, flags) {
            assert.equal(pid, 23);
            if (flags === 2) { peeks++; return -29; } // WASI EIO.
            if (flags === 1) { assert.equal(done, false); return 0; }
            assert.equal(done, true);
            return 23;
        },
        process_kill(pid, signal) {
            assert.equal(pid, 23);
            assert.equal(signal, 15);
            done = true;
            return 0;
        },
    },
});
const status = wasi.start(instance);
assert.equal(peeks, status === 98 ? 1 : 2, `guest status=${status}`);
process.exitCode = status;
