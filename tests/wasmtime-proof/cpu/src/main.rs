use std::time::Instant;

fn main() {
    let rounds = std::env::args()
        .nth(1)
        .map(|s| s.parse::<u64>().expect("invalid round count"))
        .unwrap_or(20_000_000);
    assert!(
        (1..=100_000_000).contains(&rounds),
        "round count must be 1..100000000"
    );
    let started = Instant::now();
    let mut value = 0x1234_5678_u32;
    for _ in 0..rounds {
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
    }
    let elapsed = started.elapsed().as_nanos();
    println!("CPU_ROUNDS={rounds} CPU_CHECKSUM={value:08x} CPU_NS={elapsed}");
}
