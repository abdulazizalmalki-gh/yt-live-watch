#!/usr/bin/env bash
set -euo pipefail

# live_tts.sh — Watch yt-live-watch analysis and speak new entries via Kokoro TTS.
#
# Usage:
#   ./live_tts.sh start [--html] [--play] [analysis_file] [voice]
#   ./live_tts.sh stop
#   ./live_tts.sh status
#
# Modes:
#   --play   Speak on system speakers via mpv (default if no mode given)
#   --html   Append audio players to tts-feed.html for browser playback
#   Both can be combined: --play --html
#
# Voice names: af_heart (default), af_bella, af_sarah, am_adam,
#              am_michael, bf_emma, bf_isabella, bm_george, bm_lewis
# Speed: 1.0 = normal, 1.15 = slightly faster (default)

# ── config ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/tts-venv"
TTS_PY="${SCRIPT_DIR}/tts_kokoro.py"
AUDIO_DIR="${SCRIPT_DIR}/tts-audio"
STATE_DIR="${SCRIPT_DIR}/tts-runs"
HTML_FILE="${SCRIPT_DIR}/tts-feed.html"
TTS_SPEED="${TTS_SPEED:-1.25}"

SCRIPT_PATH="$(readlink -f "$0")"

# ── helpers ───────────────────────────────────────────────────

info()  { echo "[tts] $*"; }
warn()  { echo "[tts] $*" >&2; }
die()   { echo "[tts] $*" >&2; exit 1; }
b64e()  { printf '%s' "$1" | base64 -w0; }
b64d()  { printf '%s' "$1" | base64 -d 2>/dev/null || true; }

# ── usage ─────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage:
  live_tts.sh start [--html] [--play] [file] [voice]
  live_tts.sh stop
  live_tts.sh status
  live_tts.sh serve
Modes:
  --play   System speakers via mpv
  --html   Browser feed (default: both)
EOF
}

# ── resolve analysis file ─────────────────────────────────────

resolve_analysis_file() {
    local f="$1"
    if [[ -n "$f" && -f "$f" ]]; then
        printf '%s\n' "$f"
        return
    fi
    if [[ -n "$f" ]]; then
        die "Analysis file not found: $f"
    fi
    local dir="${HOME}/yt-live-visual/analysis"
    [[ -d "$dir" ]] || die "No analysis dir at $dir"
    local found
    found="$(find "$dir" -maxdepth 1 -name '*_analysis.txt' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    [[ -n "$found" ]] || die "No *_analysis.txt files found in $dir"
    info "Auto-detected: $found" >&2
    printf '%s\n' "$found"
}

# ── install deps ──────────────────────────────────────────────

install_deps() {
    local missing=()
    command -v python3   >/dev/null 2>&1 || missing+=(python3)
    command -v ffmpeg    >/dev/null 2>&1 || missing+=(ffmpeg)
    command -v espeak-ng >/dev/null 2>&1 || missing+=(espeak-ng)
    if [[ " ${MODES[*]} " == *" play "* ]]; then
        command -v mpv >/dev/null 2>&1 || missing+=(mpv)
    fi
    [[ ${#missing[@]} -eq 0 ]] && return
    info "Installing: ${missing[*]}"
    if command -v apt >/dev/null 2>&1; then
        sudo apt update -qq && sudo apt install -y python3 python3-pip python3-venv espeak-ng ffmpeg mpv
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 python3-pip espeak-ng ffmpeg mpv
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --needed --noconfirm python python-pip espeak-ng ffmpeg mpv
    else
        die "Install manually: python3 pip espeak-ng ffmpeg mpv"
    fi
}

# ── venv + kokoro ─────────────────────────────────────────────

setup_venv() {
    if [[ ! -d "$VENV_DIR" ]]; then
        info "Creating venv: $VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi
    source "$VENV_DIR/bin/activate"
    python -m pip install -U pip -q 2>/dev/null || true
    python -c 'import kokoro; import soundfile; import numpy' 2>/dev/null || {
        info "Installing kokoro..."
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
            info "GPU detected — installing CUDA torch"
            python -m pip install -U "kokoro>=0.9.2" soundfile numpy \
                --extra-index-url https://download.pytorch.org/whl/cu126
        else
            python -m pip install -U "kokoro>=0.9.2" soundfile numpy
        fi
    }
    # Reinstall torch with CUDA if GPU is available but CPU torch is installed
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        if python -c 'import torch; assert torch.cuda.is_available()' 2>/dev/null; then
            : # CUDA torch already installed
        else
            info "GPU available but CPU torch installed — upgrading to CUDA torch"
            python -m pip install -U torch --extra-index-url https://download.pytorch.org/whl/cu126
        fi
    fi
}

create_tts_script() {
    [[ -f "$TTS_PY" ]] && rm -f "$TTS_PY"  # rebuild to pick up speed
    info "Creating TTS helper: $TTS_PY"
    cat > "$TTS_PY" <<'PYEOF'
#!/usr/bin/env python3
import sys, numpy as np, soundfile as sf
from kokoro import KPipeline
text = sys.stdin.read().strip()
out = sys.argv[1] if len(sys.argv) > 1 else ""
voice = sys.argv[2] if len(sys.argv) > 2 else "af_heart"
speed = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
if not text: sys.exit(0)
pipeline = KPipeline(lang_code="a")
parts = [a for _,_,a in pipeline(text, voice=voice, speed=speed)]
if not parts: sys.exit(0)
sf.write(out, np.concatenate(parts), 24000)
PYEOF
    chmod +x "$TTS_PY"
}

# ── GPU selection ──────────────────────────────────────────────

pick_gpu() {
    # Return the GPU index with the most free memory.
    # Falls back to "" (no restriction) if nvidia-smi is unavailable.
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        return 1  # no GPU
    fi
    local best
    best="$(nvidia-smi --query-gpu=index,memory.free --format=csv,noheader,nounits 2>/dev/null \
        | sort -t, -k2 -rn | head -1 | cut -d, -f1 | tr -d ' ')"
    if [[ -z "$best" ]]; then
        return 1
    fi
    printf '%s' "$best"
}

# ── TTS generation ────────────────────────────────────────────

generate_mp3() {
    local text="$1"
    [[ ${#text} -lt 3 ]] && return 1
    local id="$2"
    local wav="$AUDIO_DIR/${id}.wav"
    local mp3="$AUDIO_DIR/${id}.mp3"
    mkdir -p "$AUDIO_DIR"
    source "$VENV_DIR/bin/activate"

    # Pick the GPU with the most free VRAM
    local gpu
    if gpu="$(pick_gpu)"; then
        export CUDA_VISIBLE_DEVICES="$gpu"
    else
        export CUDA_VISIBLE_DEVICES=""
    fi

    python3 "$TTS_PY" "$wav" "$VOICE" "$TTS_SPEED" <<< "$text" || {
        warn "TTS generation failed for $id, skipping"
        rm -f "$wav" "$mp3"
        return 1
    }
    ffmpeg -y -loglevel quiet -i "$wav" -codec:a libmp3lame -b:a 64k "$mp3" || {
        warn "MP3 conversion failed for $id, skipping"
        rm -f "$wav" "$mp3"
        return 1
    }
    rm -f "$wav"
    printf '%s\n' "$mp3"
}

# ── HTML feed ─────────────────────────────────────────────────

JSON_FILE="${SCRIPT_DIR}/tts-entries.json"

init_html() {
    cat > "$HTML_FILE" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>yt-live-watch TTS Feed</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:system-ui,sans-serif;background:#111;color:#ddd;max-width:720px;margin:0 auto;padding:20px}
  h1{font-size:1.2em;color:#fff;margin-bottom:8px}
  .sub{color:#888;font-size:.85em;margin-bottom:24px}
  .entry{background:#1a1a1a;border:1px solid #333;border-radius:8px;padding:14px;margin-bottom:12px}
  .entry .ts{font-size:.75em;color:#888;margin-bottom:6px}
  .entry .txt{font-size:.9em;color:#ccc;margin-bottom:10px;line-height:1.4}
  .entry audio{width:100%;height:36px;border-radius:6px}
  .entry.playing{background:#1a2a1a;border-color:#3a3}
</style>
</head>
<body>
<h1>&#x1f50a; yt-live-watch &rarr; TTS Feed</h1>
<div class="sub">Live &mdash; new entries appear automatically</div>
<div id="feed"></div>
<div id="status" style="color:#555;font-size:.75em;margin-top:20px;text-align:center"></div>
<script>
const feed = document.getElementById('feed');
const status = document.getElementById('status');
const seen = new Set();
let firstLoad = true;

async function poll() {
  try {
    const r = await fetch('tts-entries.json?_=' + Date.now());
    const entries = await r.json();
    let added = 0;
    for (const e of entries) {
      if (seen.has(e.id)) continue;
      seen.add(e.id);
      const div = document.createElement('div');
      div.className = 'entry';
      div.innerHTML =
        '<div class="ts">' + e.ts + '</div>' +
        '<div class="txt">' + e.text + '</div>' +
        '<audio controls preload="none"><source src="' + e.mp3 + '" type="audio/mpeg"></audio>';
      const audio = div.querySelector('audio');
      audio.addEventListener('play', () => {
        document.querySelectorAll('audio').forEach(a => { if (a !== audio) a.pause(); });
        div.classList.add('playing');
      });
      audio.addEventListener('pause', () => div.classList.remove('playing'));
      audio.addEventListener('ended', () => div.classList.remove('playing'));
      feed.prepend(div);
      added++;
    }
    if (firstLoad && entries.length === 0) {
      feed.innerHTML = '<div class="sub" style="text-align:center;margin-top:40px">Waiting for first entry&hellip;</div>';
    }
    firstLoad = false;
    status.textContent = entries.length + ' entries \u00b7 polled ' + new Date().toLocaleTimeString() + (added ? ' \u00b7 +' + added + ' new' : '');
  } catch(e) {
    status.textContent = 'Error: ' + e.message;
  }
}
poll();
setInterval(poll, 3000);
</script>
</body>
</html>
HTMLEOF

    # Initialize empty JSON
    echo '[]' > "$JSON_FILE"
}

append_html_entry() {
    local mp3_basename="$1"
    local timestamp="$2"
    local text="$3"

    # Write text to a temp file to avoid encoding issues with env vars / argv
    local tmp_text="${HTML_FILE}.text.tmp"
    printf '%s\n' "$text" > "$tmp_text"

    python3 - "$JSON_FILE" "$timestamp" "$mp3_basename" "$tmp_text" <<'PYEOF'
import sys, json, html, os
path = sys.argv[1]
ts = sys.argv[2]
mp3 = sys.argv[3]
text_file = sys.argv[4]
with open(text_file, encoding='utf-8') as f:
    text = f.read().strip()
os.unlink(text_file)

entry = {"id": mp3.rsplit("/",1)[-1].replace(".mp3",""), "ts": ts, "mp3": mp3, "text": html.escape(text)}

try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = []
data.insert(0, entry)
with open(path, 'w') as f:
    json.dump(data, f, ensure_ascii=False)
PYEOF
}

# ── output a block in all active modes ────────────────────────

output_block() {
    local text="$1"
    local ts id mp3
    ts="$(date +%H:%M:%S)"
    id="tts_$(date +%s%N)"
    mp3="$(generate_mp3 "$text" "$id")" || return

    if [[ " ${MODES[*]} " == *" play "* ]]; then
        mpv --really-quiet "$mp3" &
    fi

    if [[ " ${MODES[*]} " == *" html "* ]]; then
        append_html_entry "tts-audio/$(basename "$mp3")" "$ts" "$text"
    fi
}

# ── analysis file parser ──────────────────────────────────────

parse_analysis() {
    local file="$1"
    local process_existing="${2:-false}"
    local block_filter="${3:-cat}"

    awk -v existing="$process_existing" '
        BEGIN { block=""; in_block=0; past_header=0; sep_count=0 }
        /^============================================================$/ {
            sep_count++
            if (sep_count >= 2) past_header=1
            next
        }
        !past_header { next }
        /^\[frame_[0-9]+\.jpg\]$/ || /^\[[0-9:.]+\] frame_[0-9]+\.jpg$/ {
            if (block != "") { print block; block="" }
            in_block=1; next
        }
        /^$/ {
            if (in_block && block != "") { print block; block="" }
            in_block=0; next
        }
        {
            if (in_block) {
                line=$0
                sub(/^[•\-] ?/, "", line)
                block = (block == "" ? line : block ". " line)
            }
        }
        END { if (block != "") print block }
    ' "$file" | $block_filter
}

# ── run: the background worker ─────────────────────────────────

run_worker() {
    info "Worker started (PID $$)"
    info "Modes: ${MODES[*]}"
    info "Voice: $VOICE"
    info "File:  $ANALYSIS_FILE"
    [[ " ${MODES[*]} " == *" html "* ]] && info "HTML:  $HTML_FILE"

    install_deps
    setup_venv
    create_tts_script

    if [[ " ${MODES[*]} " == *" html "* ]]; then
        init_html
    fi

    # Single unified pipeline: tail from start catches everything,
    # tail -F handles truncation and live appends.
    info "Processing analysis file... (Ctrl+C to stop)"

    local buffer=""
    local seen_first_sep=false
    local in_header=true

    tail -n +1 -F "$ANALYSIS_FILE" | while IFS= read -r line; do
        # Detect file truncation (new header block)
        if [[ "$line" == "============================================================" ]]; then
            if $seen_first_sep; then
                # Second separator in a header block = end of header
                if $in_header; then
                    in_header=false
                else
                    # Truncation detected: a new analysis run started
                    info "File truncated — resetting parser"
                    seen_first_sep=false
                    in_header=true
                    buffer=""
                fi
            else
                seen_first_sep=true
            fi
            continue
        fi

        # Skip everything until header is done
        if $in_header; then
            continue
        fi

        # Now past the header — process frames
        # Match frame headers anywhere in the line — tail -F can fragment them
        # when the file is being actively written. Match any digit sequence
        # ending in .jpg with optional trailing bracket.
        if [[ "$line" =~ [0-9]{6,}\.jpg\]?$ ]]; then
            # Flush buffer but skip if buffer is just a partial frame header
            if [[ -n "$buffer" ]] && ! [[ "$buffer" =~ ^\[?f?r?a?m?e?_?[0-9]*$ ]]; then
                output_block "$buffer"
            fi
            buffer=""
            continue
        fi

        if [[ -z "${line// }" ]]; then
            [[ -n "$buffer" ]] && { output_block "$buffer"; buffer=""; }
            continue
        fi

        cleaned="${line#"• "}"; cleaned="${cleaned#"•"}"
        cleaned="${cleaned#"- "}"; cleaned="${cleaned#"-"}"
        buffer="${buffer:+${buffer}. }${cleaned}"
    done
}

# ── PID / state management ────────────────────────────────────

is_running() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    return 0
}

write_meta() {
    local pid="$1"
    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/${pid}.meta" <<EOF
PID="$pid"
MODES_B64="$(b64e "${MODES[*]}")"
VOICE_B64="$(b64e "$VOICE")"
FILE_B64="$(b64e "$ANALYSIS_FILE")"
HTML_B64="$(b64e "$HTML_FILE")"
STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

load_instances() {
    RUN_PIDS=(); RUN_MODES=(); RUN_VOICES=(); RUN_FILES=(); RUN_HTMLS=(); RUN_STARTED=()
    shopt -s nullglob
    for meta in "$STATE_DIR"/*.meta; do
        unset PID MODES_B64 VOICE_B64 FILE_B64 HTML_B64 STARTED
        source "$meta" || true
        if ! is_running "${PID:-}"; then rm -f "$meta"; continue; fi
        RUN_PIDS+=("$PID")
        RUN_MODES+=("$(b64d "${MODES_B64:-}")")
        RUN_VOICES+=("$(b64d "${VOICE_B64:-}")")
        RUN_FILES+=("$(b64d "${FILE_B64:-}")")
        RUN_HTMLS+=("$(b64d "${HTML_B64:-}")")
        RUN_STARTED+=("${STARTED:-unknown}")
    done
}

# ── serve: nginx container ───────────────────────────────────

SERVE_PORT="${SERVE_PORT:-8080}"
SERVE_CONTAINER="tts-feed-nginx"
SERVE_HOST="$(hostname)"
SERVE_URL="http://${SERVE_HOST}:${SERVE_PORT}/tts-feed.html"
NGINX_CONF="${STATE_DIR}/nginx-tts.conf"

cmd_serve() {
    command -v docker >/dev/null 2>&1 || die "docker is required for serve."
    mkdir -p "$STATE_DIR"

    # Check if already running
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SERVE_CONTAINER"; then
        info "nginx already serving at $SERVE_URL"
        return 0
    fi

    # Remove dead container if exists
    docker rm -f "$SERVE_CONTAINER" 2>/dev/null || true

    # Write nginx config
    cat > "$NGINX_CONF" <<NGXEOF
server {
    listen 80;
    server_name localhost;
    root /usr/share/nginx/html;
    index tts-feed.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    location /tts-audio/ {
        add_header Cache-Control "no-cache";
        add_header Access-Control-Allow-Origin "*";
    }
}
NGXEOF

    info "Starting nginx container on port $SERVE_PORT..."
    # Ensure nginx user (uid 101) can read mounted files
    chmod -R o+rX "$SCRIPT_DIR" 2>/dev/null || true

    docker run -d \
        --name "$SERVE_CONTAINER" \
        --restart unless-stopped \
        -p "${SERVE_PORT}:80" \
        -v "${SCRIPT_DIR}:/usr/share/nginx/html:ro" \
        -v "${NGINX_CONF}:/etc/nginx/conf.d/default.conf:ro" \
        nginx:alpine

    sleep 1
    if docker ps --format '{{.Names}}' | grep -qx "$SERVE_CONTAINER"; then
        echo
        info "Serving at:"
        echo "  ▶ $SERVE_URL"
        echo
    else
        warn "Container failed to start. Check logs:"
        docker logs "$SERVE_CONTAINER" 2>&1 | tail -20
        die "nginx container failed."
    fi
}

# ── sub-commands ──────────────────────────────────────────────

cmd_start() {
    install_deps
    setup_venv
    create_tts_script

    # Auto-start nginx if html mode is active
    if [[ " ${MODES[*]} " == *" html "* ]]; then
        cmd_serve
    fi

    command -v setsid >/dev/null 2>&1 || die "setsid missing. Install util-linux."

    info "Starting in background..."
    info "Modes: ${MODES[*]}"
    info "Voice: $VOICE"
    info "File:  $ANALYSIS_FILE"
    [[ " ${MODES[*]} " == *" html "* ]] && info "HTML:  $SERVE_URL"

    mkdir -p "$AUDIO_DIR" "$STATE_DIR"

    nohup setsid "$SCRIPT_PATH" __run \
        "$ANALYSIS_FILE" "$VOICE" "${MODES[*]}" \
        >> "${STATE_DIR}/tts.log" 2>&1 < /dev/null &
    local pid="$!"

    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        die "Failed to start. Check ${STATE_DIR}/tts.log"
    fi

    write_meta "$pid"
    echo
    info "Started. PID: $pid"
    if [[ " ${MODES[*]} " == *" html "* ]]; then
        echo
        echo "  ▶ $SERVE_URL"
        echo
    fi
    echo "  Logs: ${STATE_DIR}/tts.log"
}

cmd_stop() {
    load_instances
    if [[ ${#RUN_PIDS[@]} -eq 0 ]]; then
        info "No running TTS instances."
        return 0
    fi

    echo "Running TTS instances:"
    echo
    for i in "${!RUN_PIDS[@]}"; do
        local n=$((i+1))
        echo "[$n] PID: ${RUN_PIDS[$i]}  Modes: ${RUN_MODES[$i]}  Started: ${RUN_STARTED[$i]}"
        echo "    File: ${RUN_FILES[$i]}"
    done
    echo

    local choice
    if [[ ${#RUN_PIDS[@]} -eq 1 ]]; then
        read -r -p "Stop this instance? [y/N]: " choice
        [[ "$choice" == "y" || "$choice" == "Y" ]] || { info "Cancelled."; return 0; }
        choice=1
    else
        read -r -p "Choose instance to stop, or q to cancel: " choice
        [[ "$choice" != "q" && "$choice" != "Q" ]] || { info "Cancelled."; return 0; }
    fi

    [[ "$choice" =~ ^[0-9]+$ ]] || die "Not a valid number."
    local idx=$((choice-1))
    (( idx >= 0 && idx < ${#RUN_PIDS[@]} )) || die "Choice out of range."

    local pid="${RUN_PIDS[$idx]}"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        warn "Still running, forcing..."
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$STATE_DIR/${pid}.meta"
    info "Stopped PID $pid."
}

cmd_status() {
    load_instances
    if [[ ${#RUN_PIDS[@]} -eq 0 ]]; then
        info "No running TTS instances."
    else
        echo "Running TTS instances:"
        echo
        for i in "${!RUN_PIDS[@]}"; do
            echo "[$((i+1))] PID: ${RUN_PIDS[$i]}  Modes: ${RUN_MODES[$i]}  Started: ${RUN_STARTED[$i]}"
            echo "    Voice: ${RUN_VOICES[$i]}"
            echo "    File:  ${RUN_FILES[$i]}"
            echo
        done
    fi
    # Check nginx container separately
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SERVE_CONTAINER"; then
        echo "nginx: $SERVE_URL"
    else
        echo "nginx: not running (use 'live_tts.sh serve')"
    fi
}

# ── CLI parsing ───────────────────────────────────────────────

MODES=()
VOICE="af_heart"
ANALYSIS_FILE=""

if [[ $# -eq 0 ]]; then
    usage; exit 1
fi

ACTION="${1:-}"; shift

case "$ACTION" in
    start)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --html) MODES+=("html"); shift ;;
                --play) MODES+=("play"); shift ;;
                --*) die "Unknown flag: $1" ;;
                *)
                    if [[ -z "$ANALYSIS_FILE" ]]; then
                        ANALYSIS_FILE="$1"
                    else
                        VOICE="$1"
                    fi
                    shift
                    ;;
            esac
        done
        # Default to both modes if none specified
        [[ ${#MODES[@]} -eq 0 ]] && MODES=("play" "html")
        ANALYSIS_FILE="$(resolve_analysis_file "$ANALYSIS_FILE")"
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    serve)
        cmd_serve
        ;;
    __run)
        # Internal: invoked by nohup setsid
        ANALYSIS_FILE="${1:-}"; VOICE="${2:-af_heart}"
        IFS=' ' read -r -a MODES <<< "${3:-play}"
        [[ -n "$ANALYSIS_FILE" ]] || die "__run missing analysis file"
        run_worker
        ;;
    help|-h|--help)
        usage; exit 0
        ;;
    *)
        usage; exit 1
        ;;
esac
