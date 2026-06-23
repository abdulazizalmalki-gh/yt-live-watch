#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-abdulazizalmalki-gh/yt-live-watch}"
BRANCH="${BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/yt-live-watch"
DATA_DIR="$HOME/yt-live-visual"

BIN_NAME="yt-live-watch"
BIN_PATH="$INSTALL_DIR/$BIN_NAME"
CONFIG_FILE="$CONFIG_DIR/config.env"

info() { echo "[info] $*"; }
warn() { echo "[warn] $*" >&2; }
die() { echo "[error] $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

ensure_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
  elif has sudo; then
    SUDO="sudo"
  else
    die "sudo is required unless running as root."
  fi
}

normalize_ai_url() {
  local url="$1"

  url="$(printf '%s' "$url" | tr -d '[:space:]')"
  [[ -n "$url" ]] || die "AI URL cannot be empty."

  if [[ "$url" != http://* && "$url" != https://* ]]; then
    url="http://$url"
  fi

  url="${url%/}"
  url="${url%/v1/chat/completions}"
  url="${url%/chat/completions}"
  url="${url%/v1/models}"
  url="${url%/models}"
  url="${url%/v1}"
  url="${url%/}"

  if ! [[ "$url" =~ ^https?://[^/]+:[0-9]+$ ]]; then
    die "Expected AI URL like: http://localhost:18080"
  fi

  printf '%s\n' "$url"
}

ask_ai_url() {
  echo
  echo "Enter your local AI server URL up to the port only."
  echo "Example: http://localhost:18080"
  echo

  read -r -p "Local AI base URL [http://localhost:18080]: " AI_BASE_URL

  AI_BASE_URL="${AI_BASE_URL:-http://localhost:18080}"
  AI_BASE_URL="$(normalize_ai_url "$AI_BASE_URL")"

  VLM_URL="$AI_BASE_URL/v1/chat/completions"
  MODELS_URL="$AI_BASE_URL/v1/models"

  info "AI base URL: $AI_BASE_URL"
}

install_system_deps() {
  ensure_sudo

  if has apt-get; then
    $SUDO apt-get update
    $SUDO apt-get install -y ffmpeg python3 python3-venv python3-pip pipx util-linux curl ca-certificates
  elif has dnf; then
    $SUDO dnf install -y ffmpeg python3 python3-pip pipx util-linux curl ca-certificates
  elif has pacman; then
    $SUDO pacman -Sy --needed --noconfirm ffmpeg python python-pipx util-linux curl ca-certificates
  else
    die "Unsupported distro. Install manually: ffmpeg python3 python3-venv python3-pip pipx curl"
  fi
}

setup_path() {
  mkdir -p "$INSTALL_DIR"
  export PATH="$HOME/.local/bin:$PATH"

  pipx ensurepath || true

  touch "$HOME/.bashrc"
  if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"; then
    {
      echo ""
      echo "# Added by yt-live-watch installer"
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
}

pipx_install_or_upgrade() {
  local pkg="$1"

  export PATH="$HOME/.local/bin:$PATH"

  if pipx list 2>/dev/null | grep -q "package $pkg "; then
    info "$pkg already installed, checking upgrade..."
    pipx upgrade "$pkg" || true
  else
    info "Installing $pkg..."
    pipx install "$pkg"
  fi
}

install_cli_tools() {
  pipx_install_or_upgrade streamlink
  pipx_install_or_upgrade yt-dlp
}

install_main_script() {
  local tmp
  tmp="$(mktemp)"

  info "Downloading yt-live-watch..."
  curl -fsSL "$RAW_BASE/bin/yt-live-watch" -o "$tmp"

  install -D -m 755 "$tmp" "$BIN_PATH"
  rm -f "$tmp"

  info "Installed: $BIN_PATH"
}

write_config() {
  mkdir -p "$CONFIG_DIR" "$DATA_DIR"

  cat > "$CONFIG_FILE" <<EOF
export AI_BASE_URL="$AI_BASE_URL"
export VLM_URL="$VLM_URL"
export VLM_MODEL="auto"
export WORKDIR="$DATA_DIR"
EOF

  info "Wrote config: $CONFIG_FILE"
}

test_ai() {
  if curl -fsS --max-time 5 "$MODELS_URL" >/tmp/yt-live-watch-models.json 2>/tmp/yt-live-watch-curl.err; then
    info "AI endpoint responded."
  else
    warn "Could not reach $MODELS_URL"
    warn "This is okay if your AI server is not running yet."
  fi
}

main() {
  ask_ai_url
  install_system_deps
  setup_path
  install_cli_tools
  install_main_script
  write_config
  test_ai

  echo
  echo "Install complete."
  echo
  echo "Run:"
  echo "  yt-live-watch start \"YOUTUBE_URL\" --frames 3"
  echo
  echo "If command not found:"
  echo "  source ~/.bashrc"
}

main "$@"
