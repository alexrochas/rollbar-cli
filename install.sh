#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="rollbar-cli"
BIN_DIR="${HOME}/.local/bin"
RC_FILE=""
PATH_UPDATED=0

usage() {
  cat <<EOF
Usage:
  ./install.sh [--bin-dir <path>] [--rc <path>]

Options:
  --bin-dir   Directory where command symlinks are created. Defaults to ${HOME}/.local/bin
  --rc        Shell rc file to update when the bin dir is not on PATH.
  --help      Show this help text.
EOF
}

detect_rc_file() {
  case "${SHELL:-}" in
    */zsh) printf '%s' "${HOME}/.zshrc" ;;
    */bash) printf '%s' "${HOME}/.bashrc" ;;
    *) printf '%s' "${HOME}/.zshrc" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)
      BIN_DIR="${2:-}"
      shift 2
      ;;
    --rc)
      RC_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$BIN_DIR"
chmod +x "${PROJECT_ROOT}/rollbar" "${PROJECT_ROOT}/rollbar.sh"
ln -sfn "${PROJECT_ROOT}/rollbar" "${BIN_DIR}/rollbar"

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
  PATH_UPDATED=1
  if [ -z "$RC_FILE" ]; then
    RC_FILE="$(detect_rc_file)"
  fi

  mkdir -p "$(dirname "$RC_FILE")"
  touch "$RC_FILE"

  BLOCK_START="# >>> ${PROJECT_NAME} install >>>"
  BLOCK_END="# <<< ${PROJECT_NAME} install <<<"
  TMP_FILE="$(mktemp)"

  awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    BEGIN { inblock=0 }
    $0 == start { inblock=1; next }
    $0 == end { inblock=0; next }
    !inblock { print }
  ' "$RC_FILE" > "$TMP_FILE"

  cat "$TMP_FILE" > "$RC_FILE"
  rm -f "$TMP_FILE"

  {
    printf '\n%s\n' "$BLOCK_START"
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    printf '%s\n' "$BLOCK_END"
  } >> "$RC_FILE"
fi

cat <<EOF
Installed ${PROJECT_NAME}.

Linked commands:
  - ${BIN_DIR}/rollbar -> ${PROJECT_ROOT}/rollbar

Next steps:
EOF

if [ "$PATH_UPDATED" -eq 1 ]; then
  cat <<EOF
  1. Restart your shell or run: source "${RC_FILE}"
  2. Optionally copy ${PROJECT_ROOT}/rollbar.env.example to ${PROJECT_ROOT}/.rollbar.env
  3. Verify with: command -v rollbar
EOF
else
  cat <<EOF
  1. Optionally copy ${PROJECT_ROOT}/rollbar.env.example to ${PROJECT_ROOT}/.rollbar.env
  2. Verify with: command -v rollbar
EOF
fi
