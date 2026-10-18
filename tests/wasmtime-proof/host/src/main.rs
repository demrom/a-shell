use ashell_p3_host::{Output, Runner};
use std::io::Write;
use wasmtime::{Result, bail};

extern "C" fn output(_: usize, stream: i32, bytes: *const u8, len: usize) -> isize {
    let bytes = unsafe { std::slice::from_raw_parts(bytes, len) };
    let result = if stream == 1 {
        std::io::stdout().write_all(bytes)
    } else {
        std::io::stderr().write_all(bytes)
    };
    if result.is_ok() { len as isize } else { -1 }
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.is_empty() {
        bail!("usage: ashell-p3-host COMPONENT.wasm [GUEST-ARGS...]");
    }
    let runner = Runner::new()?;
    #[cfg(feature = "compiler")]
    if args[0] == "compile" {
        if args.len() != 3 {
            bail!("usage: ashell-p3-host compile INPUT OUTPUT");
        }
        return runner.precompile(&args[1], &args[2]);
    }
    let sink = Output {
        context: 0,
        write: output,
    };
    if args[0] == "--trusted-precompiled" {
        if args.len() < 2 {
            bail!("missing trusted artifact path");
        }
        unsafe { runner.run_trusted(&args[1], &args[1..], sink) }
    } else {
        runner.run(&args[0], &args, sink)
    }
}
