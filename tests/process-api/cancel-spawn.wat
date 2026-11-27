;; Interrupt the public wasmkit command after the child writes the started
;; marker. An orphaned worker will create the leaked marker 10 seconds later.
(module
  (import "ashell_v1" "process_spawn"
    (func $spawn (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
  (import "ashell_v1" "process_wait"
    (func $wait (param i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "dash")
  (data (i32.const 16) "-c")
  (data (i32.const 24) "echo ready > process-cancel-started; sleep 10; echo leaked > process-cancel-leaked")
  (data (i32.const 112)
    "\08\00\00\00\04\00\00\00"
    "\10\00\00\00\02\00\00\00"
    "\18\00\00\00\52\00\00\00")
  (func (export "_start")
    (if (call $spawn (i32.const 8) (i32.const 4)
                     (i32.const 112) (i32.const 3)
                     (i32.const 0) (i32.const 0)
                     (i32.const 0) (i32.const 0)
                     (i32.const 3) (i32.const 144))
      (then (call $exit (i32.const 90))))
    (if (i32.ne (call $wait (i32.load (i32.const 144)) (i32.const 0) (i32.const 148))
                (i32.load (i32.const 144)))
      (then (call $exit (i32.const 91))))))
