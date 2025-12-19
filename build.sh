#!/usr/bin/env bash
# A small CLI wrapper for setting up a venv, installing deps, and running MkDocs.
# Commands:
#   build        -> create venv, install requirements, then mkdocs build
#   run [--build]-> optionally depends on build, then mkdocs serve
#   clean        -> remove build artifacts and optional caches/venv
#   lint         -> ensure autocorrect exists, download if missing, then run check
#
# Notes:
# - All error messages go to STDERR.
# - Comments are intentionally in English only.

set -Eeuo pipefail

VENV_DIR=".venv"
REQ_FILE="requirements.txt"
MKDOCS_ADDR="0.0.0.0:8000"
SITE_DIR="site"

BIN_DIR=".bin"
AUTOCORRECT_BIN="${BIN_DIR}/autocorrect"
AUTOCORRECT_URL="https://github.com/huacnlee/autocorrect/releases/download/v2.16.2/autocorrect-linux-amd64.tar.gz"

err() {
  # Print errors to STDERR
  printf "ERROR: %s\n" "$*" >&2
}

info() {
  # Print normal logs to STDOUT
  printf "%s\n" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  ./cli.sh <command> [options]

Commands:
  build
      Create venv, install requirements, run mkdocs build

  run [--build]
      Run mkdocs serve
      --build   Run build before serving

  clean
      Remove site/, cache/, and venv/

  lint
      Ensure autocorrect exists (download if missing), then run autocorrect check

Examples:
  ./cli.sh build
  ./cli.sh run
  ./cli.sh run --build
  ./cli.sh clean
  ./cli.sh lint
EOF
}

ensure_requirements() {
  if [[ ! -f "$REQ_FILE" ]]; then
    err "Missing $REQ_FILE in current directory."
    exit 1
  fi
}

ensure_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtual environment at $VENV_DIR ..."
    python3 -m venv "$VENV_DIR"
  fi
}

activate_venv() {
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
}

install_deps() {
  ensure_requirements
  info "Installing dependencies from $REQ_FILE ..."
  python -m pip install --upgrade pip >/dev/null
  pip install -r "$REQ_FILE"
}

check_mkdocs() {
  if ! command -v mkdocs >/dev/null 2>&1; then
    err "mkdocs not found. Ensure it is listed in $REQ_FILE."
    exit 1
  fi
}

# -------- LINT / autocorrect helpers --------

have_autocorrect() {
  # Prefer local .bin first, then system PATH
  if [[ -x "$AUTOCORRECT_BIN" ]]; then
    return 0
  fi
  command -v autocorrect >/dev/null 2>&1
}

download_autocorrect() {
  mkdir -p "$BIN_DIR"

  local tmpdir
  tmpdir="$(mktemp -d)"
  local archive="${tmpdir}/autocorrect.tar.gz"

  info "Downloading autocorrect from:"
  info "  $AUTOCORRECT_URL"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 1 -o "$archive" "$AUTOCORRECT_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$archive" "$AUTOCORRECT_URL"
  else
    err "Neither curl nor wget is available to download autocorrect."
    rm -rf "$tmpdir"
    exit 1
  fi

  # Extract and place binary into .bin/autocorrect
  tar -xzf "$archive" -C "$tmpdir"

  # Find the autocorrect binary in extracted files (robust to packaging)
  local found=""
  if [[ -f "${tmpdir}/autocorrect" ]]; then
    found="${tmpdir}/autocorrect"
  else
    # Try to locate it anywhere in the archive extraction
    found="$(find "$tmpdir" -maxdepth 3 -type f -name "autocorrect" -print -quit || true)"
  fi

  if [[ -z "$found" ]]; then
    err "Failed to find 'autocorrect' binary in downloaded archive."
    rm -rf "$tmpdir"
    exit 1
  fi

  mv -f "$found" "$AUTOCORRECT_BIN"
  chmod +x "$AUTOCORRECT_BIN"

  rm -rf "$tmpdir"
  info "autocorrect installed to $AUTOCORRECT_BIN"
}

ensure_autocorrect() {
  if have_autocorrect; then
    return 0
  fi

  info "autocorrect not found. Installing into $BIN_DIR/ ..."
  download_autocorrect

  if ! have_autocorrect; then
    err "autocorrect is still not available after installation."
    exit 1
  fi
}

run_autocorrect_check() {
  # Use local .bin if present; otherwise fallback to system one
  local ac="autocorrect"
  if [[ -x "$AUTOCORRECT_BIN" ]]; then
    ac="$AUTOCORRECT_BIN"
  fi

  # Basic sanity check
  if ! "$ac" --version >/dev/null 2>&1; then
    err "autocorrect exists but is not runnable."
    exit 1
  fi

  info "Running autocorrect check on current repository ..."
  # autocorrect commonly supports `check`. If your team uses a different subcommand,
  # adjust here.
  "$ac" --lint .
}

cmd_lint() {
  info "==> LINT"
  ensure_autocorrect
  run_autocorrect_check
  info "Lint completed."
}

# -------- existing commands --------

cmd_build() {
  info "==> BUILD"
  ensure_venv
  activate_venv
  install_deps
  check_mkdocs

  info "Running mkdocs build ..."
  mkdocs build
  info "Build finished. Output directory: $SITE_DIR/"
}

cmd_run() {
  info "==> RUN"

  local do_build=false

  # Parse run-specific flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build)
        do_build=true
        shift
        ;;
      *)
        err "Unknown option for run: $1"
        exit 1
        ;;
    esac
  done

  if [[ "$do_build" == true ]]; then
    cmd_build
  else
    # Ensure venv and mkdocs exist, but do not build
    ensure_venv
    activate_venv
    install_deps
    check_mkdocs
  fi

  info "Starting mkdocs server at http://${MKDOCS_ADDR} ..."
  mkdocs serve -a "$MKDOCS_ADDR"
}

cmd_clean() {
  info "==> CLEAN"

  [[ -d "$SITE_DIR" ]] && rm -rf "$SITE_DIR"
  [[ -d ".cache" ]] && rm -rf ".cache"
  [[ -d "$VENV_DIR" ]] && rm -rf "$VENV_DIR"

  info "Clean completed."
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    build) cmd_build ;;
    run)   cmd_run "$@" ;;
    clean) cmd_clean ;;
    lint)  cmd_lint ;;
    -h|--help|help) usage ;;
    *)
      err "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
