#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/lib/secret_scan.sh"

usage() {
  cat <<'EOF'
Usage:
  scan.sh [--text "<blob>" | --stdin | --file "<path>"] [--mode write|read] [--allow-redact]
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

input_text=""
input_mode="write"
allow_redact=0
src_count=0

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)
      [[ $# -ge 2 ]] || die "missing value for --text"
      input_text="$2"
      src_count=$((src_count + 1))
      shift 2
      ;;
    --stdin)
      input_text="$(cat)"
      src_count=$((src_count + 1))
      shift
      ;;
    --file)
      [[ $# -ge 2 ]] || die "missing value for --file"
      [[ -f "$2" ]] || die "file not found: $2"
      input_text="$(cat "$2")"
      src_count=$((src_count + 1))
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "missing value for --mode"
      input_mode="$2"
      shift 2
      ;;
    --allow-redact)
      allow_redact=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$src_count" -eq 1 ]] || die "specify exactly one input source: --text | --stdin | --file"
case "$input_mode" in
  write|read) ;;
  *) die "--mode must be write or read" ;;
esac

rc=0
if [[ "$input_mode" == "write" ]]; then
  if secret_scan_text_write "$input_text" "$allow_redact"; then
    :
  else
    rc=$?
    if [[ "$rc" -ne 3 ]]; then
      die "scanner failure"
    fi
  fi
else
  secret_scan_text_read "$input_text"
fi

echo "## Secret Scan Report"
echo "- Status: \`$SCAN_STATUS\`"
echo "- Mode: \`$input_mode\`"
echo "- High confidence findings: \`$SCAN_HAS_HIGH_CONF\`"
echo
echo "## Findings"
if [[ -z "$SCAN_FINDINGS" ]]; then
  echo "- none"
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    echo "- $line"
  done <<< "$SCAN_FINDINGS"
fi

echo
echo "## Redacted Preview"
preview="$(printf '%s' "$SCAN_REDACTED_TEXT" | sed -E 's/[[:space:]]+/ /g' | cut -c1-240)"
if [[ -n "$preview" ]]; then
  echo "- ${preview}"
else
  echo "- (empty)"
fi

if [[ "$SCAN_STATUS" == "blocked" ]]; then
  exit 3
fi
exit 0
