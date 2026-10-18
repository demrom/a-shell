#[cfg(not(any(feature = "https", feature = "tty")))]
wit_bindgen::generate!({
    path: "wit",
    world: "hello",
    generate_all,
});

#[cfg(feature = "https")]
wit_bindgen::generate!({ path: "wit", world: "https", generate_all });

#[cfg(feature = "tty")]
wit_bindgen::generate!({ path: "wit", world: "tty", generate_all });

struct Hello;
export!(Hello);

impl exports::wasi::cli::run::Guest for Hello {
    async fn run() -> Result<(), ()> {
        #[cfg(feature = "https")]
        {
            return https().await;
        }
        #[cfg(feature = "tty")]
        {
            return tty().await;
        }
        #[cfg(not(any(feature = "https", feature = "tty")))]
        hello().await
    }
}

async fn write(bytes: Vec<u8>) -> Result<(), ()> {
    let (mut writer, reader) = wit_stream::new();
    let (result, written) = futures::join!(
        async { wasi::cli::stdout::write_via_stream(reader).await },
        async {
            if !writer.write_all(bytes).await.is_empty() {
                return Err(());
            }
            drop(writer);
            Ok(())
        },
    );
    written?;
    result.map_err(|_| ())
}

#[cfg(not(any(feature = "https", feature = "tty")))]
async fn hello() -> Result<(), ()> {
    write(b"WASIP3_HELLO\n".to_vec()).await
}

#[cfg(feature = "https")]
async fn https() -> Result<(), ()> {
    use wasi::http::{client, types};
    let args = wasi::cli::environment::get_arguments();
    if args.len() != 3 {
        return Err(());
    }
    let headers =
        types::Headers::from_list(&[("user-agent".to_owned(), b"ashell-p3-proof/0.1".to_vec())])
            .map_err(|_| ())?;
    let options = types::RequestOptions::new();
    options
        .set_connect_timeout(Some(10_000_000_000))
        .map_err(|_| ())?;
    options
        .set_first_byte_timeout(Some(20_000_000_000))
        .map_err(|_| ())?;
    options
        .set_between_bytes_timeout(Some(20_000_000_000))
        .map_err(|_| ())?;
    let (trailers_tx, trailers_rx) = wit_future::new(|| Ok(None));
    let (request, transmit) = types::Request::new(headers, None, trailers_rx, Some(options));
    request.set_method(&types::Method::Get).map_err(|_| ())?;
    request
        .set_scheme(Some(&types::Scheme::Https))
        .map_err(|_| ())?;
    request.set_authority(Some(&args[1])).map_err(|_| ())?;
    request
        .set_path_with_query(Some(&args[2]))
        .map_err(|_| ())?;
    let (sent, (), received) = futures::join!(
        async { transmit.await.map_err(|_| ()) },
        async {
            let _ = trailers_tx.write(Ok(None)).await;
        },
        async {
            let response = client::send(request).await.map_err(|_| ())?;
            let status = response.get_status_code();
            write(format!("HTTP_STATUS={status}\n").into_bytes()).await?;

            let (_, result_rx) = wit_future::new(|| Ok(()));
            let (mut body, trailers) = types::Response::consume_body(response, result_rx);
            let mut first = true;
            let mut total = 0;
            loop {
                let (_, bytes) = body.read(Vec::with_capacity(4096)).await;
                if bytes.is_empty() {
                    break;
                }
                total += bytes.len();
                if total > 1024 * 1024 {
                    return Err(());
                }
                if first {
                    write(b"HTTP_FIRST\n".to_vec()).await?;
                    first = false;
                }
                write(bytes).await?;
            }
            trailers.await.map_err(|_| ())?;
            write(b"\nHTTP_DONE\n".to_vec()).await?;
            if first || status != 200 {
                Err(())
            } else {
                Ok(())
            }
        }
    );
    sent?;
    received
}

/// Argument 1 selects how the guest leaves raw mode: "key" (default) reads an arrow
/// key and disables it, "leave" returns with it on, "trap" traps with it on.
/// "key" without input blocks in the read until the host cancels.
#[cfg(feature = "tty")]
async fn tty() -> Result<(), ()> {
    use ashell::tty::tty::{get_size, set_raw};
    let args = wasi::cli::environment::get_arguments();
    let mode = args.get(1).map(String::as_str).unwrap_or("key");
    let size = get_size().map_err(|_| ())?;
    write(format!("SIZE={}x{}\n", size.columns, size.rows).into_bytes()).await?;
    set_raw(true).map_err(|_| ())?;
    write(b"RAW=on\n".to_vec()).await?;
    match mode {
        "leave" => return Ok(()),
        "trap" => panic!("trap with raw mode on"),
        _ => {}
    }
    let (mut input, _) = wasi::cli::stdin::read_via_stream();
    let mut keys = Vec::new();
    // Arrow keys arrive as ESC [ A..D; each read returns as soon as bytes exist.
    while keys.len() < 3 {
        let (_, bytes) = input.read(Vec::with_capacity(16)).await;
        if bytes.is_empty() {
            return Err(());
        }
        keys.extend(bytes);
    }
    let hex: String = keys.iter().map(|b| format!("{b:02x}")).collect();
    write(format!("KEYS={hex}\n").into_bytes()).await?;
    set_raw(false).map_err(|_| ())?;
    write(b"RAW=off\n".to_vec()).await
}
