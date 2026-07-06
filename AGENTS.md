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

The `--vlm-url` flag is passed through to the `__run` child process as a
command-line argument so it survives `config.env` re-sourcing in the child —
unlike an exported env var which would be clobbered.

## TTS pipeline (live_tts.sh)

Commands: `start`, `stop`, `status`, `serve`

The start command spawns a background worker that:
1. Auto-detects the latest `*_analysis.txt` file (or accepts one as arg)
2. Auto-installs missing system deps via apt/dnf/pacman, creates local venv
3. Processes the analysis file via a unified `tail -n +1 -F` pipeline that
   handles both existing frames and live appends in a single pass
4. Detects frame headers with a lenient regex to survive `tail -F` line
   fragmentation during active writes
5. Pipe each frame block through `tts_kokoro.py` → WAV → ffmpeg → MP3 (64kbps)
6. If `--play`: plays via `mpv --really-quiet` (backgrounded)
7. If `--html`: appends to `tts-entries.json`, served by nginx:alpine container

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

System (auto-installed by `install_deps()` via apt/dnf/pacman if missing):
`ffmpeg`, `python3`, `python3-venv`, `espeak-ng`, `mpv` (playback)

Python (auto-installed by `setup_venv()` into local `tts-venv/`):
`kokoro>=0.9.2`, `soundfile`, `numpy`, torch (CUDA if GPU detected, else CPU)

Stream capture: `streamlink` and/or `yt-dlp` (via pipx)
Manual: `docker` (required for `--html` / `serve` nginx container)
System: `curl`, `util-linux` (setsid)

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
