use std::ffi::{CStr, c_char};
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use tokio::io::AsyncWrite;
use tokio::sync::Notify;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{
    Config, Engine, Module, Precompiled, Result, Store, error::Context as _, format_err,
};
use wasmtime_wasi::cli::{IsTerminal, StdoutStream};
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

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    http: WasiHttpCtx,
    hooks: Hooks,
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
        })
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
        let mut store = Store::new(
            &self.engine,
            State {
                wasi: WasiCtx::builder()
                    .args(args)
                    .stdout(Stream { output, number: 1 })
                    .stderr(Stream { output, number: 2 })
                    .build(),
                table: ResourceTable::new(),
                http: WasiHttpCtx::new(),
                hooks: Hooks,
            },
        );
        store.set_epoch_deadline(1);
        if self.cancelled.load(Ordering::SeqCst) {
            return Err(format_err!("guest cancelled"));
        }
        tokio::runtime::Builder::new_current_thread().enable_all().build()?.block_on(async {
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
        })
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
