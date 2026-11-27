(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "process-control-ok\n")
  ;; stdout iovec and output byte count.
  (data (i32.const 32) "\08\00\00\00\13\00\00\00")
  (func (export "_start")
    (if (call $write (i32.const 1) (i32.const 32) (i32.const 1) (i32.const 40))
      (then unreachable))))
