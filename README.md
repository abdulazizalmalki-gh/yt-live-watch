# yt-live-watch

Watch YouTube live streams locally and get AI-powered frame-by-frame analysis in real time. Connects to any OpenAI-compatible local inference server (llama.cpp, Ollama, vLLM, etc.).

## What it does

- Captures frames from a live YouTube stream at configurable intervals
- Sends each frame to your local AI server (VLM) for analysis
- Aggregates insights into a running analysis file
- Runs multiple streams in parallel as background processes

## Prerequisites

- **Linux** (tested on Ubuntu/Debian, Fedora, Arch)
- **Local AI server** with OpenAI-compatible API (e.g., llama.cpp, Ollama)
- **A vision-capable model** (multimodal/VLM) — text-only models won't work
- `ffmpeg`, `python3`, `pipx`, `curl`

## Quick install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abdulazizalmalki-gh/yt-live-watch/main/install.sh)
```

The installer will:
1. Ask for your local AI server URL (e.g., `http://localhost:18080`)
2. Install system dependencies (`ffmpeg`, `python3`, `pipx`, etc.)
3. Install `streamlink` and `yt-dlp` via pipx
4. Download the `yt-live-watch` CLI to `~/.local/bin/`
5. Create a config file at `~/.config/yt-live-watch/config.env`

## Usage

All instances run in the background. Watch output with `tail -f` on the analysis file (path printed on start).

### Start watching a live stream

```bash
yt-live-watch start "https://www.youtube.com/watch?v=VIDEO_ID"
```

### With custom frame interval

```bash
yt-live-watch start "https://www.youtube.com/watch?v=VIDEO_ID" --frames 3
```

### With a custom analysis instruction

```bash
yt-live-watch start "https://www.youtube.com/watch?v=VIDEO_ID" --frames 5 "Describe what's happening and summarize key moments"
```

### With a custom VLM endpoint

```bash
yt-live-watch start "https://www.youtube.com/watch?v=VIDEO_ID" --vlm-url http://myllm:18080/v1
```

Overrides `VLM_URL` from config. The URL can end in `/v1` or `/v1/chat/completions`. Works with `--frames` and custom instructions. Passed through to the background worker so it survives config re-sourcing.

### Stop a running instance

```bash
yt-live-watch stop
```

Interactively choose which instance to stop. If only one is running, it stops immediately on confirmation.

### Check status of running instances

```bash
yt-live-watch status
```

Shows PID, start time, video title, output file path, and other metadata for each active instance. `list` is an alias for `status`.

## Configuration

Config file: `~/.config/yt-live-watch/config.env`

| Variable | Default | Description |
|---|---|---|
| `AI_BASE_URL` | `http://localhost:18080` | Local AI server base URL |
| `VLM_URL` | `$AI_BASE_URL/v1/chat/completions` | OpenAI-compatible completions endpoint |
| `VLM_MODEL` | `auto` | Model name (or `auto` to auto-detect) |
| `WORKDIR` | `~/yt-live-visual` | Working directory for frames, logs, analysis |
| `QUALITY` | `720p,best` | Stream quality preference |
| `WIDTH` | `960` | Frame capture width |
| `HASH_DIFF` | `6` | Minimum hash difference to trigger re-analysis |
| `MAX_TOKENS` | `300` | Max tokens per analysis response |
| `FRAME_INTERVAL` | `5` | Seconds between frame captures |
| `HEADER_MODE` | `auto` | `auto` \| `live` \| `elapsed` (timestamp header style) |

Override any variable via environment:

```bash
FRAME_INTERVAL=3 VLM_MODEL="qwen3.6-27b" yt-live-watch start "URL"
```

## How it works

1. `streamlink` or `yt-dlp` captures the live stream
2. `ffmpeg` extracts frames at the configured interval
3. Perceptual hash (`phash`) detects significant frame changes
4. Changed frames are sent as base64 images to the VLM via the OpenAI chat completions API
5. Analysis is appended to `~/yt-live-visual/analysis/<video_key>_analysis.txt`
6. A log file is written to `~/yt-live-visual/logs/` for each run

## Directory structure

```
~/yt-live-visual/
  frames/          # Raw captured frames (per video key)
  analysis/        # AI analysis output files
  runs/            # PID state files for active instances
  logs/            # Run logs
  runtime/         # Temporary runtime files
  .venv/           # Python virtual environment
```

## TTS (Text-to-Speech)

Speak live AI analysis out loud or stream it to a browser with Kokoro TTS.

### Quick start

```bash
# Start watching analysis + speak entries (default: play + html)
./live_tts.sh start

# With custom voice and speed
./live_tts.sh start ~/yt-live-visual/analysis/VIDEO_KEY_analysis.txt af_bella
```

### Modes

| Flag | Description |
|---|---|
| `--play` | Play audio through system speakers via mpv |
| `--html` | Serve a browser feed at `http://<host>:8080/tts-feed.html` via nginx container |
| (default) | Both modes active |

### Commands

```bash
./live_tts.sh start [--html] [--play] [file] [voice]   # Start TTS worker
./live_tts.sh stop                                      # Stop running worker
./live_tts.sh status                                    # Show running workers
./live_tts.sh serve                                     # Start nginx container only
```

### Voices

`af_heart` (default), `af_bella`, `af_sarah`, `am_adam`, `am_michael`, `bf_emma`, `bf_isabella`, `bm_george`, `bm_lewis`

Configure speed via `TTS_SPEED` env var (default `1.25`).

### Requirements

- `python3`, `ffmpeg`, `espeak-ng`, `mpv` (for `--play`), `docker` (for `--html` serve)
- Installs `kokoro>=0.9.2`, `soundfile`, `numpy` into a local venv at `tts-venv/`
- GPU: auto-detects NVIDIA GPUs and installs CUDA torch; picks the GPU with the most free VRAM on each generation. Falls back to CPU if no GPU available.

### How it works

1. On startup, processes all existing frames as warm-up (not just last 3)
2. `tail -F` watches the analysis file for new entries
3. Parses frame blocks (bullet points joined into sentences)
4. Picks the GPU with the most free VRAM, generates WAV via Kokoro TTS, converts to MP3
5. Failed generations are skipped with a warning — no stale JSON entries
6. Plays via mpv (`--play`) and/or appends to browser feed (`--html`)
7. Browser feed auto-polls `tts-entries.json` every 3s — exclusive playback, green card on active

## Updating

Re-run the installer to upgrade:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abdulazizalmalki-gh/yt-live-watch/main/install.sh)
```

## Disclaimer

Not affiliated with or endorsed by YouTube or Google. "YouTube" is a trademark of Google LLC. Use responsibly.

## License

MIT
