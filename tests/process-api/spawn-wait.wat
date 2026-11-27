;; The child writes stdout; the guest verifies the wait status without
;; conflating the host call's return code with the child's exit code.
(module
  (import "ashell_v1" "process_spawn"
    (func $spawn (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "ashell_v1" "process_wait"
    (func $wait (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "dash")
  (data (i32.const 16) "-c")
  (data (i32.const 24) "echo process-worker-ok; exit 7")
  ;; Three (pointer, byte length) pairs in little-endian wasm32 memory.
  (data (i32.const 80)
    "\08\00\00\00\04\00\00\00"
    "\10\00\00\00\02\00\00\00"
    "\18\00\00\00\1e\00\00\00")
  (func (export "_start")
    ;; path, argv, env, actions, flags (PATH search | inherit env), pid out
    (if (call $spawn (i32.const 8) (i32.const 4)
                     (i32.const 80) (i32.const 3)
                     (i32.const 0) (i32.const 0)
                     (i32.const 0) (i32.const 0)
                     (i32.const 3) (i32.const 128))
      (then (call $exit (i32.const 90))))
    ;; Blocking wait: pid, flags, wait status out. Return value is the PID.
    (if (i32.ne (call $wait (i32.load (i32.const 128)) (i32.const 0) (i32.const 132))
                (i32.load (i32.const 128)))
      (then (call $exit (i32.const 91))))
    (if (i32.ne (i32.load (i32.const 132)) (i32.const 1792))
      (then (call $exit (i32.const 92))))))
