;; Regenerate with wasm-tools parse, then wasm-opt 133 --asyncify
;; --pass-arg=asyncify-imports@ashell_v1.process_fork, then xxd -p.
(module
  (import "ashell_v1" "process_wait" (func $wait (param i32 i32 i32) (result i32)))
  (import "ashell_v1" "process_fork" (func $fork (param i32 i32) (result i32)))
  (import "ashell_v1" "process_spawn" (func $spawn (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "ashell_v1" "process_dup2" (func $dup2 (param i32 i32) (result i32)))
  (import "ashell_v1" "tty_raw" (func $raw (param i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (import "wasi_snapshot_preview1" "fd_close" (func $close (param i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (global (export "__stack_pointer") (mut i32) (i32.const 65520))
  (data (i32.const 8) "\10\00\00\00\15\00\00\00process-peek-fork-ok\0a")
  (func (export "_start") (local $result i32)
    ;; PEEK on an unowned child is ECHILD even without a status pointer.
    (if (i32.ne (call $wait (i32.const 1) (i32.const 2) (i32.const 0)) (i32.const -12))
      (then (call $exit (i32.const 92))))
    (local.set $result (call $fork (i32.const 128) (i32.const 8192)))
    (if (i32.eqz (local.get $result))
      (then
        ;; A real rewound child must link all imports but cannot change the TTY or write.
        (if (i32.ne (call $raw (i32.const 1)) (i32.const -58)) (then (call $exit (i32.const 95))))
        (if (i32.ne (call $write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 44)) (i32.const 52))
          (then (call $exit (i32.const 96))))
        (if (call $dup2 (i32.const 1) (i32.const 2)) (then (call $exit (i32.const 97))))
        (if (call $close (i32.const 1)) (then (call $exit (i32.const 98))))
        ;; An exec request with argc=0 returns EINVAL without a broker or worker.
        (drop (call $spawn (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)
          (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 4) (i32.const 48)))
        (call $exit (i32.const 99))))
    (if (i32.ne (local.get $result) (i32.const -28)) (then (call $exit (i32.const 93))))
    ;; The parent's stdout was not closed by the child.
    (if (call $write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 44))
      (then (call $exit (i32.const 94))))))
