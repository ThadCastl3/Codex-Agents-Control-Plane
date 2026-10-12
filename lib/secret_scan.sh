#!/usr/bin/env bash

# Bash 3.2-compatible interface to the portable scanner. Never eval its output.
SECRET_SCAN_LIBRARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_SCAN_PYTHON_SCRIPT="$SECRET_SCAN_LIBRARY_DIR/secret_scan.py"
SECRET_SCAN_RUNTIME_READY=0

SCAN_STATUS="pass"
SCAN_REDACTED_TEXT=""
SCAN_FINDINGS=""
SCAN_HAS_HIGH_CONF=0

secret_scan_reset() {
  SCAN_STATUS="pass"
  SCAN_REDACTED_TEXT=""
  SCAN_FINDINGS=""
  SCAN_HAS_HIGH_CONF=0
}

secret_scan_require_runtime() {
  [[ "$SECRET_SCAN_RUNTIME_READY" == "1" ]] && return 0
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$SECRET_SCAN_PYTHON_SCRIPT" ]]; then
    echo "Error: Python 3 secret scanner is required; no data emitted." >&2
    return 2
  fi
  if ! python3 "$SECRET_SCAN_PYTHON_SCRIPT" --self-check >/dev/null 2>&1; then
    echo "Error: secret scanner unavailable or failed; no data emitted." >&2
    return 2
  fi
  SECRET_SCAN_RUNTIME_READY=1
}

secret_scan__scan_text() {
  local input="$1" response finding count i
  secret_scan_reset
  secret_scan_require_runtime || return 2
  if ! response="$(printf '%s' "$input" | python3 "$SECRET_SCAN_PYTHON_SCRIPT" --mode read --format shell 2>/dev/null)"; then
    echo "Error: secret scanner unavailable or failed; no data emitted." >&2
    return 2
  fi
  {
    IFS= read -r SCAN_STATUS
    IFS= read -r SCAN_HAS_HIGH_CONF
    IFS= read -r count
    [[ "$SCAN_STATUS" == "pass" || "$SCAN_STATUS" == "redacted" ]] || return 2
    [[ "$SCAN_HAS_HIGH_CONF" == "0" || "$SCAN_HAS_HIGH_CONF" == "1" ]] || return 2
    [[ "$count" =~ ^[0-9]+$ ]] || return 2
    i=0
    while (( i < count )); do
      IFS= read -r finding || return 2
      if [[ -n "$SCAN_FINDINGS" ]]; then
        SCAN_FINDINGS="$SCAN_FINDINGS"$'\n'"$finding"
      else
        SCAN_FINDINGS="$finding"
      fi
      i=$((i + 1))
    done
    SCAN_REDACTED_TEXT="$(cat)"
  } <<< "$response"
}

secret_scan_text_write() {
  local input="$1" allow_redact="${2:-0}"
  secret_scan__scan_text "$input" || return 2
  if [[ "$SCAN_HAS_HIGH_CONF" -eq 1 && "$allow_redact" != "1" ]]; then
    SCAN_STATUS="blocked"
    return 3
  fi
  return 0
}

secret_scan_text_read() {
  secret_scan__scan_text "$1"
}

secret_scan_file_write() {
  local path="$1" allow_redact="${2:-0}" input
  [[ -f "$path" ]] || return 2
  input="$(cat "$path")" || return 2
  secret_scan_text_write "$input" "$allow_redact"
}

secret_scan_file_read() {
  local path="$1" input
  [[ -f "$path" ]] || return 2
  input="$(cat "$path")" || return 2
  secret_scan_text_read "$input"
}

secret_scan_filter_read() {
  secret_scan_require_runtime || return 2
  python3 "$SECRET_SCAN_PYTHON_SCRIPT" --mode read --format text
}

secret_scan_filter_file_read() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Error: scanner source file unavailable; no data emitted." >&2
    return 2
  fi
  secret_scan_filter_read < "$path"
}

secret_scan_run_read_main() {
  local child_status
  secret_scan_require_runtime || return 2
  SECRET_SCAN_OUTPUT_DIR="$(mktemp -d)" || return 2
  trap 'rm -rf "$SECRET_SCAN_OUTPUT_DIR"' EXIT
  # Its own cleanup traps stay in the subshell; retain its errexit behavior.
  set +e
  ( set -e; "$@" ) > "$SECRET_SCAN_OUTPUT_DIR/stdout" 2> "$SECRET_SCAN_OUTPUT_DIR/stderr"
  child_status=$?
  set -e
  if ! secret_scan_filter_file_read "$SECRET_SCAN_OUTPUT_DIR/stdout" > "$SECRET_SCAN_OUTPUT_DIR/safe-stdout" ||
     ! secret_scan_filter_file_read "$SECRET_SCAN_OUTPUT_DIR/stderr" > "$SECRET_SCAN_OUTPUT_DIR/safe-stderr"; then
    echo "Error: secret scanner failed; reader output withheld." >&2
    return 2
  fi
  cat "$SECRET_SCAN_OUTPUT_DIR/safe-stdout"
  cat "$SECRET_SCAN_OUTPUT_DIR/safe-stderr" >&2
  return "$child_status"
}
