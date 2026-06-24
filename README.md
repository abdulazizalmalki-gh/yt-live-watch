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

## Updating

Re-run the installer to upgrade:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abdulazizalmalki-gh/yt-live-watch/main/install.sh)
```

## License

MIT
