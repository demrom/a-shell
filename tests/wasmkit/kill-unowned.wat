;; No worker is started in this producer smoke. An unowned PID is rejected.
(module
  (import "ashell_v1" "process_kill" (func $kill (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "\10\00\00\00\10\00\00\00process-kill-ok\0a")
  (func (export "_start")
    (if (i32.ne (call $kill (i32.const 1) (i32.const 0)) (i32.const -71))
      (then (call $exit (i32.const 90))))
    (if (call $write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 40))
      (then (call $exit (i32.const 91))))))
