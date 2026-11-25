;; Regenerate hello.hex with: wat2wasm hello.wat -o hello.wasm && xxd -p hello.wasm > hello.hex
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; One iovec: address 8, length 17.
  (data (i32.const 0) "\08\00\00\00\11\00\00\00Hello from WASI!\0a")
  (func (export "_start")
    (if (call $write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 32))
      (then unreachable))))
