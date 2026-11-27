//! Preview2 guest for sockets-contract.sh: `tcp HOST:PORT` connects (HOST may be a
//! name, which needs ip-name-lookup); `udp HOST:PORT` sends one datagram.
use std::net::{TcpStream, UdpSocket};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [mode, addr] = args.as_slice() else {
        eprintln!("usage: ashell-sockets-probe tcp|udp HOST:PORT");
        std::process::exit(2);
    };
    let result = match mode.as_str() {
        "tcp" => TcpStream::connect(addr).map(drop),
        "udp" => UdpSocket::bind("127.0.0.1:0").and_then(|socket| socket.send_to(b"ping", addr)).map(drop),
        _ => {
            eprintln!("unknown mode {mode}");
            std::process::exit(2);
        }
    };
    match result {
        Ok(()) => println!("{mode} ok {addr}"),
        Err(error) => {
            println!("{mode} error {addr}: {:?} {error}", error.kind());
            std::process::exit(1);
        }
    }
}
