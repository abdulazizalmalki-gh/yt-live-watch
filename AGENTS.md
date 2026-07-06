# AGENTS.md

## Project overview

yt-live-watch captures frames from YouTube live streams and sends them to a local VLM for AI-powered analysis in real time. A companion TTS pipeline speaks those analyses aloud via Kokoro TTS and serves a browser feed.

All scripts are pure Bash. No framework, no package manager — just `curl | bash` install.

## Repository structure

```
.
├── bin/yt-live-watch       # Main CLI (installed to ~/.local/bin/)
├── install.sh              # One-shot installer
├── live_tts.sh             # TTS orchestrator (start/stop/status/serve)
├── tts_kokoro.py           # Kokoro pipeline wrapper (stdin→WAV)
├── tts-feed.html           # Browser frontend (auto-polling audio cards)
├── .gitignore              # Ignores tts-entries.json, tts-audio/, tts-runs/, tts-venv/
└── README.md
```

## Key conventions

- All scripts use `set -euo pipefail`
- Config lives at `~/.config/yt-live-watch/config.env` (sourced, env-var style)
- Runtime data at `~/yt-live-visual/` (frames/, analysis/, runs/, logs/, runtime/, .venv/)
- Background processes use `nohup setsid` — never plain `&`
- Process state stored as `$STATE_DIR/<pid>.meta` files (base64-encoded key=value)
- Process liveness checked via `kill -0` + `/proc/<pid>/cmdline` containing `__run`
- Stopping uses `kill -TERM -- -$pid` (process group), then `kill -KILL` fallback
- Video keys computed from YouTube URL: extract `v=` param, fallback to sha1 hash

## Main CLI (bin/yt-live-watch)

Commands: `start`, `stop`, `status` (alias: `list`)

Start spawns a background worker that:
1. Captures stream via `streamlink` or `yt-dlp` piped to `ffmpeg`
2. Extracts frames at `FRAME_INTERVAL` seconds, resized to `WIDTH`px
3. Perceptual hash (`phash`) dedup — only sends frames exceeding `HASH_DIFF` threshold
4. Sends base64-encoded frames to VLM via OpenAI-compatible `/v1/chat/completions`
5. Appends analysis to `~/yt-live-visual/analysis/<video_key>_analysis.txt`

Key env vars: `VLM_URL`, `VLM_MODEL`, `WIDTH`, `HASH_DIFF`, `MAX_TOKENS`, `FRAME_INTERVAL`, `HEADER_MODE`, `QUALITY`

CLI flags: `--frames N`, `--vlm-url http://host:port/v1`

## TTS pipeline (live_tts.sh)

Commands: `start`, `stop`, `status`, `serve`

The start command spawns a background worker that:
1. Auto-detects the latest `*_analysis.txt` file (or accepts one as arg)
2. Installs deps + creates a local venv at `tts-venv/`
3. Parses analysis file via `awk`: skips header (two `====` separators), extracts bullet-point blocks per frame entry
4. Pipe each block through `tts_kokoro.py` → WAV → ffmpeg → MP3 (64kbps)
5. If `--play`: plays via `mpv --really-quiet` (backgrounded)
6. If `--html`: appends to `tts-entries.json`, served by nginx:alpine container

Worker watches the analysis file with `tail -n 0 -F` — new appends are picked up live.
On startup, all existing frames are processed as warm-up (not just the last 3).

Config: `TTS_SPEED` (default 1.25), voice via positional arg (default `af_heart`)

GPU: `pick_gpu()` queries `nvidia-smi` for free VRAM and sets `CUDA_VISIBLE_DEVICES` to
the GPU with the most headroom. Falls back to CPU if no GPU or nvidia-smi unavailable.
Failed TTS/ffmpeg generations are skipped with a warning — no stale JSON entries.

## Analysis file format

The VLM output follows this structure in `*_analysis.txt`:

```
============================================================
(header — skipped by TTS parser)
============================================================
[frame_1.jpg]
• bullet point one
• bullet point two

[frame_2.jpg]
• next frame analysis
```

Header mode (`live` vs `elapsed`) controls whether frames are labeled with `[HH:MM:SS]` timestamps or `[frame_N.jpg]`.

## Dependencies

System: `ffmpeg`, `python3`, `python3-venv`, `pipx`, `curl`, `util-linux` (setsid)
Stream capture: `streamlink` and/or `yt-dlp` (via pipx)
TTS: `kokoro>=0.9.2`, `soundfile`, `numpy`, `espeak-ng`, `mpv` (playback), `docker` (serve)

## Common workflows

```bash
# Install fresh
bash <(curl -fsSL https://raw.githubusercontent.com/abdulazizalmalki-gh/yt-live-watch/main/install.sh)

# Start watching a stream
yt-live-watch start "https://www.youtube.com/watch?v=VIDEO_ID" --frames 3

# Start with custom VLM endpoint
yt-live-watch start "https://www.youtube.com/watch?v=VIDEO_ID" --vlm-url http://host:port/v1

# Start TTS on the analysis
./live_tts.sh start       # auto-detect latest analysis file
./live_tts.sh start --play ~/yt-live-visual/analysis/KEY_analysis.txt af_heart

# Check status
yt-live-watch status
./live_tts.sh status

# Stop
yt-live-watch stop
./live_tts.sh stop
```

## Git

- Only source files committed — generated artifacts (tts-entries.json, tts-audio/, tts-runs/, tts-venv/) are gitignored
- Flat repo structure, no build system, no CI
