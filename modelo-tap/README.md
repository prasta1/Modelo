# modelo-tap

A tiny, zero-dependency GPU-metrics exporter for [Modelo](../README.md). Run it on a
remote NVIDIA inference box (a DGX Spark, or any Linux machine with `nvidia-smi`) and
point a Modelo server at it; Modelo polls it and renders VRAM / power / temperature /
utilization on the **Status** dashboard and **Console** inspector.

The name is a double meaning: a beer **tap**, and a network/metrics **tap**.

## Why it exists

`nvidia-smi` can't report VRAM on a GB10 / DGX Spark — CPU and GPU share unified LPDDR5X,
so memory shows as `[Not Supported]`. `modelo-tap` reads `nvidia-smi` (power / temp / util)
*and* `/proc/meminfo` (unified VRAM) and serves both as JSON. It's a single std-only Rust
binary (~450 KB), independent of your inference server — it works the same whether the box
runs vLLM, llama.cpp, llama-swap, or Ollama.

## HTTP API

Plain HTTP, JSON responses, permissive CORS. One request per connection.

| Method & path | Response |
|---|---|
| `GET /gpu`    | GPU snapshot (see below) |
| `GET /health` | `{"ok":true}` |

```jsonc
// GET /gpu
{
  "vram_used_gb": 38.2, "vram_total_gb": 96.0,
  "power_w": 142.0, "power_limit_w": 350.0,
  "temp_c": 61.0, "util_pct": 78.0,
  "devices": [
    { "name": "NVIDIA GB10", "util_pct": 78.0,
      "mem_used_gb": 38.2, "mem_total_gb": 96.0,
      "temp_c": 61.0, "power_w": 142.0, "power_limit_w": 350.0 }
  ]
}
```

> Fields that `nvidia-smi` reports as `[Not Supported]` / `[N/A]` parse to `0`. On
> unified-memory boxes the top-level `vram_*` comes from `/proc/meminfo` and is mirrored
> onto the first device row so it isn't blank.

## Install

Needs the Rust toolchain and `nvidia-smi` on the box.

```bash
git clone https://github.com/heath0xFF/Modelo && cd Modelo/modelo-tap
cargo build --release
sudo install -m755 target/release/modelo-tap /usr/local/bin/modelo-tap
```

> Prefer not to install Rust on the box? Cross-compile from another Linux machine with
> `rustup target add aarch64-unknown-linux-gnu` (or `…-musl` for a fully static binary)
> and `scp` the result over. The binary has zero dependencies.

## Run

```bash
modelo-tap --port 9099             # serves GET /gpu (binds 0.0.0.0 by default)
curl -s http://localhost:9099/gpu  # sanity check — JSON with VRAM/power/temp
```

Flags: `--port <n>` (default `9099`), `--bind <addr>` (default `0.0.0.0`).

Run it as a service to persist across reboots:

```ini
# /etc/systemd/system/modelo-tap.service
[Unit]
Description=Modelo GPU metrics agent (modelo-tap)
After=network.target

[Service]
ExecStart=/usr/local/bin/modelo-tap --port 9099
Restart=on-failure
User=YOUR_USER

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now modelo-tap
```

## Point Modelo at it

In Modelo → **Settings → Servers**, set the server's **Agent URL** to `http://<host>:9099`.

- **Same network:** use the box's hostname/IP; if it has a firewall, allow port `9099`.
- **Not on the same network:** SSH-tunnel and use `localhost`:
  ```bash
  ssh -N -L 9099:localhost:9099 you@host
  ```
  `modelo-tap` has **no authentication** — on an untrusted network run it with
  `--bind 127.0.0.1` and reach it only through the tunnel.

## Security

No auth, permissive CORS — designed for a trusted LAN or an SSH tunnel. Do not expose
port `9099` to the public internet.
