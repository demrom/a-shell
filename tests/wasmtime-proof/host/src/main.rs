use ashell_p3_host::{Output, Runner, ashell_p3_run, ashell_p3_run_trusted};
use std::ffi::CString;
use std::io::Write;
use std::sync::Arc;
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
    let runner = Arc::new(Runner::new()?);
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
    let trusted = args[0] == "--trusted-precompiled";
    let args = if trusted {
        if args.len() < 2 {
            bail!("missing trusted artifact path");
        }
        &args[1..]
    } else {
        &args[..]
    };
    #[cfg(all(unix, not(target_os = "ios")))]
    {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        // Register before starting the guest so Ctrl-C cannot race handler installation.
        let mut interrupt = {
            let _entered = runtime.enter();
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?
        };
        let interrupt_runner = runner.clone();
        std::thread::spawn(move || {
            if runtime.block_on(interrupt.recv()).is_some() { interrupt_runner.cancel(); }
        });
    }
    let arguments = args.iter().map(|arg| CString::new(arg.as_str())).collect::<std::result::Result<Vec<_>, _>>()?;
    let pointers = arguments.iter().map(|arg| arg.as_ptr()).collect::<Vec<_>>();
    let status = unsafe {
        let run = if trusted { ashell_p3_run_trusted } else { ashell_p3_run };
        run(Arc::as_ptr(&runner), arguments[0].as_ptr(), pointers.len(), pointers.as_ptr(), sink)
    };
    if status != 0 {
        std::process::exit(status);
    }
    Ok(())
}
