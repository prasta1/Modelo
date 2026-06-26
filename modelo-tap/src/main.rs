//! modelo-tap — a dependency-free GPU-stats exporter for Modelo.
//!
//! Run it on an NVIDIA box (e.g. a DGX Spark) and point a Modelo server at it
//! (set its "Agent URL" to `http://<host>:9099`). Modelo polls `GET /gpu` and
//! renders the result on the Status dashboard and Console inspector.
//!
//! Why both nvidia-smi *and* /proc/meminfo: on GB10 / DGX Spark, nvidia-smi
//! reports memory as "[Not Supported]" because CPU and GPU share unified
//! LPDDR5X. So power/temp/util come from nvidia-smi, and VRAM (used/total)
//! comes from /proc/meminfo.
//!
//! Usage:  modelo-tap [--port 9099] [--bind 127.0.0.1]
//! Binds loopback by default; pass `--bind 0.0.0.0` to expose it on the LAN
//! (e.g. so a Modelo machine on another host can reach it).

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;

fn main() {
    let mut port: u16 = 9099;
    let mut bind = "127.0.0.1".to_string();   // loopback by default; LAN exposure is opt-in via --bind 0.0.0.0
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--port" => {
                if let Some(p) = args.next() {
                    port = p.parse().unwrap_or(port);
                }
            }
            "--bind" => {
                if let Some(b) = args.next() {
                    bind = b;
                }
            }
            "-h" | "--help" => {
                println!("modelo-tap [--port 9099] [--bind 127.0.0.1]  (--bind 0.0.0.0 to expose on the LAN)");
                return;
            }
            _ => {}
        }
    }

    let addr = format!("{bind}:{port}");
    let listener = match TcpListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("modelo-tap: cannot bind {addr}: {e}");
            std::process::exit(1);
        }
    };
    println!("modelo-tap listening on http://{addr}  (GET /gpu)");

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                // One request per connection; ignore handler errors.
                let _ = handle(s);
            }
            Err(e) => eprintln!("modelo-tap: accept error: {e}"),
        }
    }
}

fn handle(mut stream: TcpStream) -> std::io::Result<()> {
    use std::time::Duration;
    // Bound each connection so one idle/slow client can't stall the single-threaded
    // accept loop and starve telemetry for everyone else.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let mut buf = [0u8; 1024];
    let n = stream.read(&mut buf)?;
    let req = String::from_utf8_lossy(&buf[..n]);
    let path = req
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .unwrap_or("/");

    let (status, body) = match path {
        p if p.starts_with("/gpu") => ("200 OK", gpu_json()),
        "/health" => ("200 OK", "{\"ok\":true}".to_string()),
        _ => ("404 Not Found", "{\"error\":\"not found\"}".to_string()),
    };

    let resp = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: application/json\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(resp.as_bytes())?;
    stream.flush()
}

struct Device {
    name: String,
    util: f64,
    mem_used_gb: f64,
    mem_total_gb: f64,
    temp: f64,
    power: f64,
    power_limit: f64,
}

fn gpu_json() -> String {
    let devices = query_nvidia_smi();
    let (uni_used, uni_total) = unified_memory_gb();

    let power: f64 = devices.iter().map(|d| d.power).sum();
    let power_limit: f64 = devices.iter().map(|d| d.power_limit).sum();
    let temp = devices.iter().map(|d| d.temp).fold(0.0, f64::max);
    let util = devices.iter().map(|d| d.util).fold(0.0, f64::max);

    // Prefer unified memory (correct on GB10); fall back to summed nvidia-smi.
    let (vram_used, vram_total) = if uni_total > 0.0 {
        (uni_used, uni_total)
    } else {
        (
            devices.iter().map(|d| d.mem_used_gb).sum(),
            devices.iter().map(|d| d.mem_total_gb).sum(),
        )
    };

    let mut dev_json = String::from("[");
    for (i, d) in devices.iter().enumerate() {
        if i > 0 {
            dev_json.push(',');
        }
        // On unified-memory boxes, show the unified figure on the first device
        // so the row isn't blank.
        let (mu, mt) = if d.mem_total_gb <= 0.0 && i == 0 {
            (vram_used, vram_total)
        } else {
            (d.mem_used_gb, d.mem_total_gb)
        };
        dev_json.push_str(&format!(
            "{{\"name\":{},\"util_pct\":{:.1},\"mem_used_gb\":{:.2},\"mem_total_gb\":{:.2},\"temp_c\":{:.1},\"power_w\":{:.1},\"power_limit_w\":{:.1}}}",
            json_str(&d.name), d.util, mu, mt, d.temp, d.power, d.power_limit
        ));
    }
    dev_json.push(']');

    format!(
        "{{\"vram_used_gb\":{vram_used:.2},\"vram_total_gb\":{vram_total:.2},\
          \"power_w\":{power:.1},\"power_limit_w\":{power_limit:.1},\
          \"temp_c\":{temp:.1},\"util_pct\":{util:.1},\"devices\":{dev_json}}}"
    )
}

/// `nvidia-smi --query-gpu=...`. Fields that read "[Not Supported]"/"[N/A]"
/// parse to 0.
fn query_nvidia_smi() -> Vec<Device> {
    let out = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit",
            "--format=csv,noheader,nounits",
        ])
        .output();
    let Ok(out) = out else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|line| {
            let f: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
            let g = |i: usize| f.get(i).map(|s| num(s)).unwrap_or(0.0);
            Device {
                name: f.first().map(|s| s.to_string()).unwrap_or_default(),
                util: g(1),
                mem_used_gb: g(2) / 1024.0, // MiB → GB-ish
                mem_total_gb: g(3) / 1024.0,
                temp: g(4),
                power: g(5),
                power_limit: g(6),
            }
        })
        .collect()
}

/// Unified memory from /proc/meminfo (kB) → (used_gb, total_gb).
fn unified_memory_gb() -> (f64, f64) {
    let Ok(text) = std::fs::read_to_string("/proc/meminfo") else {
        return (0.0, 0.0);
    };
    let mut total_kb = 0.0;
    let mut avail_kb = 0.0;
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("MemTotal:") {
            total_kb = num(v);
        } else if let Some(v) = line.strip_prefix("MemAvailable:") {
            avail_kb = num(v);
        }
    }
    let total_gb = total_kb / 1_000_000.0;
    let used_gb = (total_kb - avail_kb) / 1_000_000.0;
    (used_gb.max(0.0), total_gb)
}

/// Parse the leading number out of a token, tolerating units and N/A markers.
fn num(s: &str) -> f64 {
    let t = s.trim().trim_start_matches('[');
    let digits: String = t
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-')
        .collect();
    digits.parse().unwrap_or(0.0)
}

/// Minimal JSON string escaping for the GPU name.
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
