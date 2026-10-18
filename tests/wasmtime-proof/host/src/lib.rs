use std::ffi::{CStr, c_char};
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::task::JoinHandle;
use tokio::sync::Notify;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{
    Config, Engine, Module, Precompiled, Result, Store, error::Context as _, format_err,
};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};
use wasmtime_wasi::p3::bindings::Command;
use wasmtime_wasi::{WasiCtx, WasiCtxView, WasiView};
use wasmtime_wasi_http::{WasiHttpCtx, WasiHttpCtxView, WasiHttpHooks, WasiHttpView};

/// The caller owns the context until run returns. Writes must be thread-safe and
/// return the number of bytes written, or -1 on error. No callback is retained.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct Output {
    pub context: usize,
    pub write: extern "C" fn(usize, i32, *const u8, usize) -> isize,
}

#[derive(Clone, Copy)]
struct Stream {
    output: Output,
    number: i32,
}

impl IsTerminal for Stream {
    fn is_terminal(&self) -> bool {
        false
    }
}

impl StdoutStream for Stream {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(*self)
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let n = (self.output.write)(
            self.output.context,
            self.number,
            bytes.as_ptr(),
            bytes.len(),
        );
        Poll::Ready(if n < 0 || n as usize > bytes.len() {
            Err(io::Error::other("host output callback failed"))
        } else {
            Ok(n as usize)
        })
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

wasmtime::component::bindgen!({
    path: "../wit/ashell-tty.wit",
    world: "ashell:tty/terminal",
});
use ashell::tty::tty::{ErrorCode, Size};

/// The a-Shell terminal behind `ashell:tty`. Same semantics as the ashell_v1
/// tty_size/tty_raw imports; errors are negative WASI errno values. Callbacks
/// run on host threads and must be thread-safe. `read` blocks until at least
/// one byte is available and returns it unbuffered: bytes read, 0 at EOF, -1 on
/// error. It must return once the terminal is gone: a read in flight when a
/// guest is cancelled is abandoned, not joined. No callback is retained after
/// the context is released by the caller.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct Tty {
    pub context: usize,
    pub size: extern "C" fn(usize, *mut u32, *mut u32) -> i32,
    pub raw: extern "C" fn(usize, i32) -> i32,
    pub read: extern "C" fn(usize, *mut u8, usize) -> isize,
}

const WASI_ENOSYS: i32 = 52;
const WASI_ENOTSUP: i32 = 58;
const WASI_ENOTTY: i32 = 59;

fn error_code(status: i32) -> ErrorCode {
    match -status {
        WASI_ENOTTY => ErrorCode::NotATerminal,
        WASI_ENOSYS | WASI_ENOTSUP => ErrorCode::Unsupported,
        _ => ErrorCode::Io,
    }
}

/// Guest stdin fed by Tty::read. Clones share one pending read, as stdin must.
#[derive(Clone)]
struct TtyStdin {
    tty: Tty,
    shared: Arc<Mutex<Pending>>,
}
#[derive(Default)]
struct Pending {
    ready: Vec<u8>,
    job: Option<JoinHandle<io::Result<Vec<u8>>>>,
}

impl IsTerminal for TtyStdin {
    fn is_terminal(&self) -> bool {
        true
    }
}
impl StdinStream for TtyStdin {
    fn async_stream(&self) -> Box<dyn AsyncRead + Send + Sync> {
        Box::new(self.clone())
    }
}
impl AsyncRead for TtyStdin {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let mut pending = self.shared.lock().unwrap();
        loop {
            if !pending.ready.is_empty() {
                let n = pending.ready.len().min(out.remaining());
                out.put_slice(&pending.ready[..n]);
                pending.ready.drain(..n);
                return Poll::Ready(Ok(()));
            }
            let tty = self.tty;
            let job = pending.job.get_or_insert_with(|| {
                tokio::task::spawn_blocking(move || {
                    let mut buffer = [0u8; 256];
                    let n = (tty.read)(tty.context, buffer.as_mut_ptr(), buffer.len());
                    if n < 0 {
                        Err(io::Error::other("host terminal read failed"))
                    } else {
                        Ok(buffer[..n as usize].to_vec())
                    }
                })
            });
            let result = match Pin::new(job).poll(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(result) => result,
            };
            pending.job = None;
            let bytes = result.map_err(io::Error::other)??;
            if bytes.is_empty() {
                return Poll::Ready(Ok(()));
            }
            pending.ready = bytes;
        }
    }
}

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    http: WasiHttpCtx,
    hooks: Hooks,
    tty: Option<Tty>,
    raw: bool,
}
impl ashell::tty::tty::Host for State {
    fn get_size(&mut self) -> Result<Size, ErrorCode> {
        let tty = self.tty.ok_or(ErrorCode::Unsupported)?;
        let (mut columns, mut rows) = (0, 0);
        match (tty.size)(tty.context, &mut columns, &mut rows) {
            0 => Ok(Size { columns, rows }),
            status => Err(error_code(status)),
        }
    }
    fn set_raw(&mut self, enabled: bool) -> Result<(), ErrorCode> {
        let tty = self.tty.ok_or(ErrorCode::Unsupported)?;
        match (tty.raw)(tty.context, enabled as i32) {
            0 => {
                self.raw = enabled;
                Ok(())
            }
            status => Err(error_code(status)),
        }
    }
}
struct Hooks;
impl WasiHttpHooks for Hooks {}
impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}
impl WasiHttpView for State {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView {
            ctx: &mut self.http,
            table: &mut self.table,
            hooks: &mut self.hooks,
        }
    }
}

/// One worker owns a runner. Cancel may run concurrently; run and delete may not.
/// A runner can execute another guest after cancellation has returned.
pub struct Runner {
    engine: Engine,
    cancelled: AtomicBool,
    wake: Notify,
    tty: Mutex<Option<Tty>>,
}
impl Runner {
    pub fn new() -> Result<Self> {
        let mut config = Config::new();
        config.target("pulley64")?;
        config.wasm_component_model_async(true);
        config.epoch_interruption(true);
        Ok(Self {
            engine: Engine::new(&config)?,
            cancelled: AtomicBool::new(false),
            wake: Notify::new(),
            tty: Mutex::new(None),
        })
    }
    /// Offer the terminal bridge to later runs; None withdraws it. A guest that
    /// imports ashell:tty then sees get-size/set-raw fail with unsupported.
    pub fn set_tty(&self, tty: Option<Tty>) {
        *self.tty.lock().unwrap() = tty;
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.engine.increment_epoch();
        self.wake.notify_one();
    }
    #[cfg(feature = "compiler")]
    pub fn precompile(&self, input: &str, output: &str) -> Result<()> {
        let bytes = std::fs::read(input)?;
        let artifact = if wasmparser::Parser::is_component(&bytes) {
            self.engine.precompile_component(&bytes)?
        } else {
            self.engine.precompile_module(&bytes)?
        };
        std::fs::write(output, artifact)?;
        Ok(())
    }
    pub fn run(&self, path: &str, args: &[String], output: Output) -> Result<()> {
        self.run_impl(path, args, output, false)
    }
    /// # Safety
    /// Only load artifacts produced by this exact engine/configuration from a
    /// trusted build. Wasmtime deserialization does not validate machine code.
    pub unsafe fn run_trusted(&self, path: &str, args: &[String], output: Output) -> Result<()> {
        self.run_impl(path, args, output, true)
    }
    fn run_impl(&self, path: &str, args: &[String], output: Output, trusted: bool) -> Result<()> {
        self.cancelled.store(false, Ordering::SeqCst);
        let bytes = std::fs::read(path)?;
        let is_module = if trusted {
            match Engine::detect_precompiled(&bytes) {
                Some(Precompiled::Module) => true,
                Some(Precompiled::Component) => false,
                _ => return Err(format_err!("not a trusted precompiled Wasmtime artifact")),
            }
        } else {
            !wasmparser::Parser::is_component(&bytes)
        };
        if is_module {
            return self.run_p1(&bytes, args, output, trusted);
        }
        let component = if trusted {
            unsafe { Component::deserialize(&self.engine, &bytes) }?
        } else {
            #[cfg(feature = "compiler")]
            {
                Component::new(&self.engine, &bytes).context("compile guest component")?
            }
            #[cfg(not(feature = "compiler"))]
            {
                return Err(format_err!(
                    "compiler-free build requires --trusted-precompiled"
                ));
            }
        };
        if component.component_type().exports(&self.engine)
            .any(|(name, _)| name.starts_with("wasi:cli/run@0.2."))
        {
            return self.run_p2(&component, args, output);
        }
        let mut linker = Linker::new(&self.engine);
        wasmtime_wasi::p3::add_to_linker(&mut linker)?;
        wasmtime_wasi_http::p3::add_to_linker(&mut linker)?;
        ashell::tty::tty::add_to_linker::<_, wasmtime::component::HasSelf<_>>(&mut linker, |state| state)?;
        let tty = *self.tty.lock().unwrap();
        let mut wasi = WasiCtx::builder();
        wasi.args(args)
            .stdout(Stream { output, number: 1 })
            .stderr(Stream { output, number: 2 });
        if let Some(tty) = tty {
            wasi.stdin(TtyStdin { tty, shared: Arc::default() });
        }
        let mut store = Store::new(
            &self.engine,
            State {
                wasi: wasi.build(),
                table: ResourceTable::new(),
                http: WasiHttpCtx::new(),
                hooks: Hooks,
                tty,
                raw: false,
            },
        );
        store.set_epoch_deadline(1);
        if self.cancelled.load(Ordering::SeqCst) {
            return Err(format_err!("guest cancelled"));
        }
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        let outcome = runtime.block_on(async {
            let run = async {
                let command = Command::instantiate_async(&mut store, &component, &linker)
                    .await.context("instantiate released 0.3.1 guest with stock hosts")?;
                store.run_concurrent(async move |store| command.wasi_cli_run().call_run(store).await)
                    .await.context("schedule guest")?.context("guest trapped")?
                    .map_err(|()| format_err!("guest returned failure"))
            };
            tokio::pin!(run);
            loop {
                tokio::select! {
                    result = &mut run => return result,
                    _ = self.wake.notified() => {
                        if self.cancelled.load(Ordering::SeqCst) { return Err(format_err!("guest cancelled")); }
                    }
                }
            }
        });
        // Every exit path ends here: return, trap and cancellation. A terminal
        // read still blocked in the host is abandoned with the runtime.
        if let (true, Some(tty)) = (store.data().raw, tty) {
            (tty.raw)(tty.context, 0);
        }
        runtime.shutdown_background();
        outcome
    }

    fn run_p2(&self, component: &Component, args: &[String], output: Output) -> Result<()> {
        let mut linker = Linker::new(&self.engine);
        wasmtime_wasi::p2::add_to_linker_async(&mut linker)?;
        wasmtime_wasi_http::p2::add_only_http_to_linker_async(&mut linker)?;
        let mut wasi = WasiCtx::builder();
        wasi.args(args)
            .stdout(Stream { output, number: 1 })
            .stderr(Stream { output, number: 2 })
            .inherit_network()
            .preopened_dir("/", "/", wasmtime_wasi::FsPerms::ReadWrite)?;
        let mut store = Store::new(&self.engine, State {
            wasi: wasi.build(), table: ResourceTable::new(),
            http: WasiHttpCtx::new(), hooks: Hooks,
        });
        store.set_epoch_deadline(1);
        if self.cancelled.load(Ordering::SeqCst) {
            return Err(format_err!("guest cancelled"));
        }
        tokio::runtime::Builder::new_current_thread().enable_all().build()?.block_on(async {
            let run = async {
                let command = wasmtime_wasi::p2::bindings::Command::instantiate_async(&mut store, component, &linker).await?;
                match command.wasi_cli_run().call_run(&mut store).await {
                    Err(error) if error.downcast_ref::<wasmtime_wasi::I32Exit>().is_some_and(|exit| exit.0 == 0) => Ok(()),
                    result => result?.map_err(|()| format_err!("guest returned failure")),
                }
            };
            tokio::pin!(run);
            loop {
                tokio::select! {
                    result = &mut run => return result,
                    _ = self.wake.notified() => {
                        if self.cancelled.load(Ordering::SeqCst) { return Err(format_err!("guest cancelled")); }
                    }
                }
            }
        })
    }

    fn run_p1(&self, bytes: &[u8], args: &[String], output: Output, trusted: bool) -> Result<()> {
        let module = if trusted {
            unsafe { Module::deserialize(&self.engine, bytes) }?
        } else {
            #[cfg(feature = "compiler")]
            {
                Module::new(&self.engine, bytes)?
            }
            #[cfg(not(feature = "compiler"))]
            {
                return Err(format_err!(
                    "compiler-free build requires --trusted-precompiled"
                ));
            }
        };
        let mut linker = wasmtime::Linker::new(&self.engine);
        wasmtime_wasi::p1::add_to_linker_sync(&mut linker, |ctx| ctx)?;
        let ctx = WasiCtx::builder()
            .args(args)
            .allow_blocking_current_thread(true)
            .stdout(Stream { output, number: 1 })
            .stderr(Stream { output, number: 2 })
            .build_p1();
        let mut store = Store::new(&self.engine, ctx);
        store.set_epoch_deadline(1);
        if self.cancelled.load(Ordering::SeqCst) {
            return Err(format_err!("guest cancelled"));
        }
        let instance = linker.instantiate(&mut store, &module)?;
        let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
        match start.call(&mut store, ()) {
            Err(error)
                if error
                    .downcast_ref::<wasmtime_wasi::I32Exit>()
                    .is_some_and(|e| e.0 == 0) =>
            {
                Ok(())
            }
            result => result,
        }
    }
}

/// Returns null if engine creation fails; the caller then reports failure.
#[unsafe(no_mangle)]
pub extern "C" fn ashell_p3_new() -> *mut Runner {
    Runner::new()
        .map(|runner| Box::into_raw(Box::new(runner)))
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// runner must be live until every concurrent cancel and run has returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ashell_p3_cancel(runner: *const Runner) {
    if let Some(runner) = unsafe { runner.as_ref() } {
        runner.cancel();
    }
}

/// Offers the terminal bridge to later runs of this runner; null withdraws it.
/// Without it a guest importing ashell:tty gets error-code unsupported.
/// # Safety
/// runner is live; tty is null or points to a valid Tty whose context outlives
/// every run that may use it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ashell_p3_set_tty(runner: *const Runner, tty: *const Tty) {
    if let Some(runner) = unsafe { runner.as_ref() } {
        runner.set_tty(unsafe { tty.as_ref() }.copied());
    }
}

/// # Safety
/// runner is exclusively owned, with no active run or cancel operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ashell_p3_delete(runner: *mut Runner) {
    if !runner.is_null() {
        drop(unsafe { Box::from_raw(runner) });
    }
}

/// # Safety
/// runner, path, argv and output context stay live for this call. argv contains
/// argc valid UTF-8 C strings; no second run may use runner concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ashell_p3_run(
    runner: *const Runner,
    path: *const c_char,
    argc: usize,
    argv: *const *const c_char,
    output: Output,
) -> i32 {
    unsafe { run_ffi(runner, path, argc, argv, output, false) }
}

/// # Safety
/// Same pointer requirements as ashell_p3_run; the artifact must additionally
/// come from the exact trusted Wasmtime build/configuration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ashell_p3_run_trusted(
    runner: *const Runner,
    path: *const c_char,
    argc: usize,
    argv: *const *const c_char,
    output: Output,
) -> i32 {
    unsafe { run_ffi(runner, path, argc, argv, output, true) }
}

unsafe fn run_ffi(
    runner: *const Runner,
    path: *const c_char,
    argc: usize,
    argv: *const *const c_char,
    output: Output,
    trusted: bool,
) -> i32 {
    let result = (|| -> Result<()> {
        let runner = unsafe { runner.as_ref() }.ok_or_else(|| format_err!("null runner"))?;
        let path = unsafe { CStr::from_ptr(path) }.to_str()?;
        let args = unsafe { std::slice::from_raw_parts(argv, argc) }
            .iter()
            .map(|p| unsafe { CStr::from_ptr(*p) }.to_str().map(str::to_owned))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        runner.run_impl(path, &args, output, trusted)
    })();
    match result {
        Ok(()) => 0,
        Err(error) if error.downcast_ref::<wasmtime_wasi::I32Exit>().is_some() => {
            error.downcast_ref::<wasmtime_wasi::I32Exit>().unwrap().0
        }
        Err(error) => {
            let text = format!("ashell-p3: {error:#}\n");
            (output.write)(output.context, 2, text.as_ptr(), text.len());
            if unsafe { runner.as_ref() }.is_some_and(|r| r.cancelled.load(Ordering::SeqCst)) {
                130
            } else {
                1
            }
        }
    }
}
