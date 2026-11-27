// Load the "require" function:
importScripts("require.js");
// make the "require" function available to all
Tarp.require({expose: true});
// Have a global variable:
var global = self;
var sharedArray;
const decoder = new TextDecoder();
// and a Buffer variable
var Buffer = require('buffer').Buffer;
var process = require('process');

// Functions to deal with WebAssembly:
// These should load a wasm program: http://andrewsweeney.net/post/llvm-to-wasm/
/* Array of bytes to base64 string decoding */
// Modules for @wasmer:
const { WASI, WASIExitError } = require('@wasmer/wasi/lib');
const { WASI_FILETYPE_SOCKET_STREAM, WASI_RIGHT_FD_READ, WASI_RIGHT_FD_WRITE } = require('@wasmer/wasi/lib/constants');
const browserBindings = require('@wasmer/wasi/lib/bindings/browser').default;
const WasmFs = require('@wasmer/wasmfs').WasmFs;
// Experiment: don't call lowerI64Imports, see if that works.
// const lowerI64Imports = require("@wasmer/wasm-transformer").lowerI64Imports

function b64ToUint6 (nChr) {

	return nChr > 64 && nChr < 91 ?
		nChr - 65
		: nChr > 96 && nChr < 123 ?
		nChr - 71
		: nChr > 47 && nChr < 58 ?
		nChr + 4
		: nChr === 43 ?
		62
		: nChr === 47 ?
		63
		:
		0;

}

function base64DecToArr (sBase64, nBlockSize) {
	var
	sB64Enc = sBase64.replace(/[^A-Za-z0-9\+\/]/g, ""), nInLen = sB64Enc.length,
		nOutLen = nBlockSize ? Math.ceil((nInLen * 3 + 1 >>> 2) / nBlockSize) * nBlockSize : nInLen * 3 + 1 >>> 2, aBytes = new Uint8Array(nOutLen);

	for (var nMod3, nMod4, nUint24 = 0, nOutIdx = 0, nInIdx = 0; nInIdx < nInLen; nInIdx++) {
		nMod4 = nInIdx & 3;
		nUint24 |= b64ToUint6(sB64Enc.charCodeAt(nInIdx)) << 18 - 6 * nMod4;
		if (nMod4 === 3 || nInLen - nInIdx === 1) {
			for (nMod3 = 0; nMod3 < 3 && nOutIdx < nOutLen; nMod3++, nOutIdx++) {
				aBytes[nOutIdx] = nUint24 >>> (16 >>> nMod3 & 24) & 255;
			}
			nUint24 = 0;
		}
	}
	return aBytes;
}

function bytesToBase64(bytes) {
  const binString = Array.from(bytes, (byte) =>
    String.fromCodePoint(byte),
  ).join("");
  return btoa(binString);
}


function interactiveKeyboardInput(inputLength) {
	// Send a request to the outside:
	Atomics.store(sharedArray, 0, 0);
	sharedArray[0] = 0;
	postMessage(["keyboard", inputLength]);
	// Freeze ourselves until the response is ready:
	Atomics.wait(sharedArray, 0, 0);
	result = '';
	// Decode the response (by slices of 2047 bytes):
	let length = sharedArray[0] - 1;
	while (length >= 0) {
		let bytes = new Int8Array(length);
		for (let i = 0; i < length; i++) {
			result += String.fromCharCode(sharedArray[i+1]);
		}
		if (length == 2047) {
			// wait for the next chunk:
			// Need to tell it to send the next chunk!
			Atomics.store(sharedArray, 0, 0);
			sharedArray[0] = 0;
			postMessage(["sendNextChunk"]);
			Atomics.wait(sharedArray, 0, 0, 10000);
			length = sharedArray[0] - 1;
		} else {
			break;
		}
	}
	// Need to base64-encode in case there are emojis or other utf-8 characters:
	return bytesToBase64(new TextEncoder().encode(result));
}

function prompt(string) {
	// Send a request to the outside:
	sharedArray[0] = 0;
	Atomics.store(sharedArray, 0, 0);
	postMessage(["prompt", string]);
	// Freeze ourselves until the response is ready:
	Atomics.wait(sharedArray, 0, 0, 500);
	result = '';
	// Decode the response (by slices of 8192 bytes):
	let length = sharedArray[0] - 1;
	while (length >= 0) {
		let bytes = new Int8Array(length);
		for (let i = 0, j=1; i < length; i+=4, j++) {
			bytes[i  ] = sharedArray[j] & 0xFF;
			bytes[i+1] = (sharedArray[j] >>  8) & 0xFF;
			bytes[i+2] = (sharedArray[j] >> 16) & 0xFF;
			bytes[i+3] = (sharedArray[j] >> 24) & 0xFF;
		}
		result += decoder.decode(bytes);
		if (length == 8192) {
			// wait for the next chunk:
			// Need to tell it to send the next chunk!
			sharedArray[0] = 0;
			Atomics.store(sharedArray, 0, 0);
			postMessage(["sendNextChunk"]);
			let reason = Atomics.wait(sharedArray, 0, 0, 10000);
			length = sharedArray[0] - 1;
		} else {
			break;
		}
	}
	return result;
}

// ashell_v1 process imports use the Preview 1 errno numbering.
function processImports(wasi, memory, env, generation, prelude) {
	const errno = { badFD: 8, tooBig: 1, fault: 21, encoding: 25, invalid: 28, io: 29, tooManyFDs: 33, notSupported: 58 };
	const ioLimit = 4096;
	const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
	const encoder = new TextEncoder();
	const maxRequestBytes = 256 * 1024;
	const maxVector = 4096;
	const response = new SharedArrayBuffer(8196);
	const responseLength = new Int32Array(response, 0, 1);
	const streams = prelude?.streams ?? new Map([0, 1, 2].map(fd => [wasi.FD_MAP.get(fd), fd]));

	function exchange(message) {
		const json = JSON.stringify({ ...message, generation });
		if (json.length > maxRequestBytes || encoder.encode(json).length > maxRequestBytes) return `-${errno.tooBig} 0`;
		// A late legacy I/O reply must not release a pending process request.
		Atomics.store(responseLength, 0, 0);
		postMessage(['processPrompt', 'ashell-process\n' + json, response]);
		Atomics.wait(responseLength, 0, 0);
		const length = Atomics.load(responseLength, 0) - 1;
		// TextDecoder does not accept shared-buffer views in every browser.
		return decoder.decode(new Uint8Array(response, 4, length).slice());
	}

	function request(message) {
		const match = /^(-?\d+) (\d+)(?: ([A-Za-z0-9+/=]+))?$/.exec(exchange(message));
		if (!match) return [-errno.io, 0];
		return [Number(match[1]), Number(match[2]), match[3]];
	}

	function decode(view, pointer, length) {
		pointer >>>= 0;
		length >>>= 0;
		if (pointer + length > view.byteLength) throw -errno.fault;
		if (length > maxRequestBytes) throw -errno.tooBig;
		let string;
		try {
			string = utf8.decode(new Uint8Array(view.buffer, pointer, length));
		} catch (_) {
			throw -errno.encoding;
		}
		if (string.includes('\0')) throw -errno.invalid;
		return string;
	}

	function vector(view, pointer, count) {
		pointer >>>= 0;
		count >>>= 0;
		if (count > maxVector) throw -errno.tooBig;
		if (pointer + count * 8 > view.byteLength) throw -errno.fault;
		const strings = [];
		let bytes = 0;
		for (let i = 0; i < count; i++, pointer += 8) {
			const length = view.getUint32(pointer + 4, true);
			bytes += length;
			if (bytes > maxRequestBytes) throw -errno.tooBig;
			strings.push(decode(view, view.getUint32(pointer, true), length));
		}
		return strings;
	}

	function viewAt(output, length = 4) {
		const buffer = memory()?.buffer;
		if (!buffer || (output >>> 0) + length > buffer.byteLength) throw -errno.fault;
		return new DataView(buffer);
	}

	function install(fd, handle, write) {
		wasi.FD_MAP.set(fd, {
			processHandle: handle,
			// Opaque handles must never reach Wasmer's legacy raw-descriptor prompts.
			real: -1,
			filetype: WASI_FILETYPE_SOCKET_STREAM,
			rights: { base: write ? WASI_RIGHT_FD_WRITE : WASI_RIGHT_FD_READ, inheriting: BigInt(0) },
		});
	}

	function nextFD(excluding) {
		for (let fd = 0; fd <= 0x7fffffff; fd++) {
			if (fd !== excluding && !wasi.FD_MAP.has(fd)) return fd;
		}
		throw -errno.tooManyFDs;
	}

	function processEntry(fd) {
		const entry = wasi.FD_MAP.get(fd >>> 0);
		return entry?.processHandle === undefined ? undefined : entry;
	}

	function childStreams(view, actions, count) {
		count >>>= 0;
		actions >>>= 0;
		if (count > maxVector) throw -errno.tooBig;
		if (actions + count * 12 > view.byteLength) throw -errno.fault;
		const fds = new Map(wasi.FD_MAP);
		for (let i = 0; i < count; i++, actions += 12) {
			const op = view.getInt32(actions, true);
			const source = view.getInt32(actions + 4, true);
			const target = view.getInt32(actions + 8, true);
			if (!fds.has(source)) throw -errno.badFD;
			if (op === 1) {
				if (target < 0 || target > 2) throw -errno.notSupported;
				fds.set(target, fds.get(source));
			} else if (op === 2) {
				fds.delete(source);
			} else {
				throw -errno.invalid;
			}
		}
		return [0, 1, 2].map(fd => {
			const entry = fds.get(fd);
			if (!entry) throw -errno.badFD;
			if (entry.processHandle !== undefined) return entry.processHandle;
			const stream = streams.get(entry);
			if (stream === undefined) throw -errno.notSupported;
			return stream;
		});
	}

	// wasi-libc stops scanning preopens on EBADF. A pipe is never a preopen.
	for (const name of ['fd_prestat_get', 'fd_prestat_dir_name']) {
		const original = wasi.wasiImport[name];
		wasi.wasiImport[name] = (fd, ...args) => processEntry(fd) ? errno.badFD : original(fd, ...args);
	}

	const originalClose = wasi.wasiImport.fd_close;
	wasi.wasiImport.fd_close = fd => {
		const entry = processEntry(fd);
		if (!entry) return originalClose(fd);
		const [status] = request({ op: 'close', fd: entry.processHandle });
		// The host consumes the owned handle, even if close reports an error.
		wasi.FD_MAP.delete(fd >>> 0);
		return -status;
	};

	function closeForReplacement(fd) {
		// Wasmer's preopen entries use placeholder raw numbers, not owned host FDs.
		if (wasi.FD_MAP.get(fd)?.fakePath !== undefined) {
			wasi.FD_MAP.delete(fd);
			return 0;
		}
		return wasi.wasiImport.fd_close(fd);
	}

	const originalRenumber = wasi.wasiImport.fd_renumber;
	wasi.wasiImport.fd_renumber = (from, to) => {
		if (!processEntry(from) && !processEntry(to)) return originalRenumber(from, to);
		const source = wasi.FD_MAP.get(from >>> 0);
		if (!source || !wasi.FD_MAP.has(to >>> 0)) return errno.badFD;
		if (from === to) return 0;
		const status = closeForReplacement(to >>> 0);
		if (status !== 0) return status;
		wasi.FD_MAP.delete(from >>> 0);
		wasi.FD_MAP.set(to >>> 0, source);
		return 0;
	};

	function processIO(entry, write, iovs, count, transferred) {
		const right = write ? WASI_RIGHT_FD_WRITE : WASI_RIGHT_FD_READ;
		if ((entry.rights.base & right) === BigInt(0)) return errno.badFD;
		try {
			const view = viewAt(transferred);
			iovs >>>= 0;
			count >>>= 0;
			if (iovs + count * 8 > view.byteLength) return errno.fault;
			for (let i = 0; i < count; i++) {
				const offset = iovs + i * 8;
				if (view.getUint32(offset, true) + view.getUint32(offset + 4, true) > view.byteLength) return errno.fault;
			}
			for (let i = 0; i < count; i++) {
				const offset = iovs + i * 8;
				const length = Math.min(view.getUint32(offset + 4, true), ioLimit);
				if (length === 0) continue;
				const buffer = new Uint8Array(view.buffer, view.getUint32(offset, true), length);
				const [status, moved, data] = request(write
					? { op: 'write', fd: entry.processHandle, data: bytesToBase64(buffer) }
					: { op: 'read', fd: entry.processHandle, length });
				if (status !== 0) return -status;
				if (moved > length) return errno.io;
				if (!write && moved !== 0) {
					const bytes = base64DecToArr(data ?? '');
					if (bytes.length !== moved) return errno.io;
					buffer.set(bytes);
				}
				// Pipe I/O may return a short transfer, including the first nonempty iovec.
				view.setUint32(transferred >>> 0, moved, true);
				return 0;
			}
			view.setUint32(transferred >>> 0, 0, true);
			return 0;
		} catch (_) {
			return errno.fault;
		}
	}

	for (const [name, write] of [['fd_read', false], ['fd_write', true]]) {
		const original = wasi.wasiImport[name];
		wasi.wasiImport[name] = (fd, iovs, count, transferred) => {
			const entry = processEntry(fd);
			return entry ? processIO(entry, write, iovs, count, transferred) : original(fd, iovs, count, transferred);
		};
	}

	return {
		process_pipe(pair) {
			if (prelude) return -errno.notSupported;
			try {
				if (!pair) return -errno.fault;
				const output = viewAt(pair, 8);
				const read = nextFD();
				const write = nextFD(read);
				const reply = exchange({ op: 'pipe' });
				const failure = /^(-\d+) 0$/.exec(reply);
				if (failure) return Number(failure[1]);
				const pairReply = /^0 (\d+) (\d+)$/.exec(reply);
				const validHandle = part => /^\d+$/.test(part) && Number(part) >= 3 && Number(part) <= 0x7fffffff;
				if (!pairReply || !validHandle(pairReply[1]) || !validHandle(pairReply[2]) || Number(pairReply[1]) === Number(pairReply[2])) {
					// Do not publish a partial pair; release the recoverable host handles.
					if (reply.startsWith('0 ')) {
						const candidates = reply.split(' ').slice(1, 3).filter(validHandle).map(Number);
						for (const fd of new Set(candidates)) request({ op: 'close', fd });
					}
					return -errno.io;
				}
				install(read, Number(pairReply[1]), false);
				install(write, Number(pairReply[2]), true);
				output.setInt32(pair >>> 0, read, true);
				output.setInt32((pair >>> 0) + 4, write, true);
				return 0;
			} catch (error) {
				return Number.isInteger(error) ? error : -errno.io;
			}
		},
		process_dup2(source, target) {
			if (source < 0 || target < 0 || !wasi.FD_MAP.has(source)) return -errno.badFD;
			if (source === target) return 0;
			if (prelude) {
				// A private fd map borrows the parent's entries. No physical dup or
				// close occurs until spawn resolves final stdio against those entries.
				wasi.FD_MAP.set(target, wasi.FD_MAP.get(source));
				return 0;
			}
			const entry = processEntry(source);
			if (!entry) return -errno.notSupported;
			const [status, handle] = request({ op: 'dup', fd: entry.processHandle });
			if (status !== 0) return status;
			if (!handle) return -errno.io;
			if (wasi.FD_MAP.has(target)) {
				const error = closeForReplacement(target);
				if (error !== 0) {
					request({ op: 'close', fd: handle });
					return -error;
				}
			}
			wasi.FD_MAP.set(target, { ...entry, processHandle: handle, rights: { ...entry.rights } });
			return 0;
		},
		process_spawn(path, pathLength, argv, argc, envp, envc, actions, actionCount, flags, child) {
			try {
				if (Boolean(prelude) !== Boolean(flags & 4)) return -errno.notSupported;
				if (flags & ~7 || argc === 0 || ((flags & 2) && envc !== 0)) return -errno.invalid;
				const view = viewAt(child);
				const [result, pid] = request({
					op: 'spawn',
					path: decode(view, path, pathLength),
					argv: vector(view, argv, argc),
					env: flags & 2 ? Object.entries(env).map(([name, value]) => name + '=' + value)
					              : vector(view, envp, envc),
					searchPath: Boolean(flags & 1),
					streams: childStreams(view, actions, actionCount),
				});
				if (result === 0) {
					if (prelude) {
						prelude.admitted = pid;
						throw prelude;
					}
					view.setInt32(child >>> 0, pid, true);
				} else if (prelude) {
					prelude.execError = result;
				}
				return result;
			} catch (error) {
				if (prelude && error === prelude) throw error;
				return Number.isInteger(error) ? error : -errno.io;
			}
		},
		process_kill(child, signal) {
			if (prelude) return -errno.notSupported;
			try {
				const [result] = request({ op: 'kill', child, signal });
				return result;
			} catch (error) {
				return Number.isInteger(error) ? error : -errno.io;
			}
		},
		process_wait(child, flags, status) {
			if (prelude) return -errno.notSupported;
			try {
				if (flags === 2) return request({ op: 'peek', child })[0];
				if (flags & ~1) return -errno.invalid;
				const view = viewAt(status);
				// Do not block the UI actor while the worker is running.
				for (;;) {
					const [result, encoded] = request({ op: 'wait', child });
					if (result > 0) view.setInt32(status >>> 0, encoded, true);
					if (result !== 0 || flags & 1) return result;
					Atomics.wait(sharedArray, 0, Atomics.load(sharedArray, 0), 20);
				}
			} catch (error) {
				return Number.isInteger(error) ? error : -errno.io;
			}
		},
	};
}

// This is a private pre-exec continuation, not a second running process. Its
// only external effect is admission of one executable on the existing broker.
function runProcessModule(module, args, cwd, tty, env, generation) {
	const unsupported = -58;
	const maxForkMemory = 32 * 1024 * 1024;
	const readOnly = new Set(['args_get', 'args_sizes_get', 'environ_get', 'environ_sizes_get',
		'clock_time_get', 'clock_res_get', 'fd_fdstat_get', 'fd_filestat_get', 'proc_exit']);

	function makeRun(prelude) {
		const wasi = new WASI({
			preopens: {'.': cwd, '/': '/'},
			args,
			env,
			bindings: { ...browserBindings, fs: new WasmFs().fs },
		});
		if (tty !== 1) wasi.bindings.isTTY = () => false;
		const streams = prelude?.streams ?? new Map([0, 1, 2].map(fd => [wasi.FD_MAP.get(fd), fd]));
		if (prelude) wasi.FD_MAP = new Map(prelude.fds);
		let instance, capture, result;
		const processes = processImports(wasi, () => instance?.exports.memory, env, generation, prelude);
		processes.process_fork = (data, length) => {
			const exports = instance?.exports;
			if (!exports) return unsupported;
			data >>>= 0;
			length >>>= 0;
			if (result !== undefined) {
				if (exports.asyncify_get_state() !== 2 || data !== capture.data || length !== capture.length) {
					throw new Error('invalid fork rewind');
				}
				exports.asyncify_stop_rewind();
				const value = result;
				result = capture = undefined;
				return value;
			}
			if (prelude || capture || !(exports.__stack_pointer instanceof WebAssembly.Global) ||
				!['start_unwind', 'stop_unwind', 'start_rewind', 'stop_rewind', 'get_state']
					.every(name => typeof exports['asyncify_' + name] === 'function')) return unsupported;
			const buffer = exports.memory?.buffer;
			if (!(buffer instanceof ArrayBuffer)) return unsupported; // No shared memory.
			if (buffer.byteLength > maxForkMemory) return -48;
			if (!data || data % 4 || length < 8 || data + length > buffer.byteLength || exports.asyncify_get_state() !== 0) return -28;
			const view = new DataView(buffer);
			view.setUint32(data, data + 8, true);
			view.setUint32(data + 4, data + length, true);
			capture = {data, length, stack: exports.__stack_pointer.value};
			exports.asyncify_start_unwind(data);
			return 0; // Not observed by instrumented code while unwinding.
		};
		const imports = wasi.getImports(module);
		if (prelude) {
			// Child close and dup2 only change borrowed entries in the local map.
			// Never let a prelude call path_open, fd_write or other external I/O.
			const preview = imports.wasi_snapshot_preview1;
			for (const name of Object.keys(preview)) {
				if (!readOnly.has(name)) preview[name] = () => -unsupported;
			}
			preview.fd_close = fd => wasi.FD_MAP.delete(fd >>> 0) ? 0 : 8;
		}
		instance = new WebAssembly.Instance(module, { ...imports, ashell_v1: processes });
		return {
			get capture() { return capture; },
			exports: instance.exports,
			start: () => wasi.start(instance),
			rewind(saved, value) {
				capture = saved;
				result = value;
				instance.exports.__stack_pointer.value = saved.stack;
				instance.exports.asyncify_start_rewind(saved.data);
				wasi.start(instance);
			},
			cloneBranch(saved) {
				const exports = instance.exports;
				if (exports.asyncify_get_state() !== 1) throw new Error('invalid fork unwind');
				exports.asyncify_stop_unwind();
				const view = new DataView(exports.memory.buffer);
				const cursor = view.getUint32(saved.data, true);
				if (cursor < saved.data + 8 || cursor > saved.data + saved.length ||
					view.getUint32(saved.data + 4, true) !== saved.data + saved.length) return -28;
				if (view.byteLength > maxForkMemory) return -48;
				const childPrelude = {fds: wasi.FD_MAP, streams, admitted: 0, execError: unsupported};
				try {
					const child = makeRun(childPrelude);
					const pages = (exports.memory.buffer.byteLength - child.exports.memory.buffer.byteLength) / 65536;
					if (pages > 0) child.exports.memory.grow(pages);
					new Uint8Array(child.exports.memory.buffer).set(new Uint8Array(exports.memory.buffer));
					child.rewind(saved, 0);
				} catch (error) {
					if (error === childPrelude) return childPrelude.admitted || -29;
					if (!(error instanceof WASIExitError)) return unsupported;
				}
				return childPrelude.execError;
			},
		};
	}

	const parent = makeRun();
	parent.start();
	while (parent.capture) {
		const saved = parent.capture;
		parent.rewind(saved, parent.cloneBranch(saved));
	}
}

// bufferString: program in base64 format
// args: arguments (argv[argc])
// stdinBuffer: standard input
// cwd: current working directory
function executeWebAssemblyWorker(bufferString, args, cwd, tty, env, generation) {
	// Input: base64 encoded binary wasm file
	if (typeof window !== 'undefined') {
		if (!('WebAssembly' in window)) {
			window.webkit.messageHandlers.aShell.postMessage('WebAssembly not supported');
			return;
		}
	}
	var arrayBuffer = base64DecToArr(bufferString); 
	// Experiment: don't call lowerI64Imports, see if that works.
	const loweredWasmBytes = arrayBuffer; // lowerI64Imports(arrayBuffer);
	var errorMessage = '';
	var errorCode = 0; 
	// TODO: link with other libraries/frameworks? impossible, I guess.
	try {
		const module = new WebAssembly.Module(loweredWasmBytes);
		runProcessModule(module, args, cwd, tty, env, generation);
	}
	catch (error) {
		// WASI returns an error even in some cases where things went well. 
		// We find the type of the error, and return the appropriate error message
		// This line must be commented on release (it breaks tlmgr):
		// console.log("Wasm error: " + error.message + " Error code: " + error.code);
		if (error instanceof WASIExitError) {
			// The browser binding implements ordinary proc_exit by throwing.
			errorCode = error.code;
		} else if (error.code === undefined) {
			errorCode = 1; 
			errorMessage = 'wasm: ' + error;
		} else if (error.code != null) { 
			// Numerical error code. Send the return code back to Swift.
			errorCode = error.code;
			if (errorCode > 0) 
				errorMessage = error.message;
		} else {
			errorCode = 1; 
		}
	}
	postMessage(["commandTerminated", errorCode, errorMessage]);
}

onmessage = (e) => {
	if (typeof sharedArray === 'undefined') {
		sharedArray = new Int32Array(e.data[5]);
	}
	executeWebAssemblyWorker(e.data[0], e.data[1], e.data[2], e.data[3], e.data[4], e.data[6]);
}
