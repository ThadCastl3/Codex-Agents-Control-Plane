#!/usr/bin/env bash
# Bash 3.2-compatible bridge to the stdlib transaction helper.

MEMORY_TRANSACTION_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/memory_transaction.py"

memory_transaction_begin() {
  local root="$1" script="$2"
  shift 2
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: memory writes require Python 3 for transaction locking." >&2
    exit 4
  fi
  if python3 "$MEMORY_TRANSACTION_HELPER" validate --root "$root"; then
    return 0
  fi
  exec python3 "$MEMORY_TRANSACTION_HELPER" run --root "$root" -- bash "$script" "$@"
}

memory_create_file() {
  python3 "$MEMORY_TRANSACTION_HELPER" publish --create "$1"
}

memory_replace_file() {
  python3 "$MEMORY_TRANSACTION_HELPER" publish --replace "$1"
}
