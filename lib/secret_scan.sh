#!/usr/bin/env bash

# Shared secret scanning helpers for write/read memory flows.
# This library is bash 3.2 compatible and relies on global outputs:
#   SCAN_STATUS, SCAN_REDACTED_TEXT, SCAN_FINDINGS, SCAN_HAS_HIGH_CONF

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

secret_scan__add_finding() {
  local level="$1"
  local label="$2"
  local line="${level}: ${label}"
  if [[ -n "$SCAN_FINDINGS" ]] && printf '%s\n' "$SCAN_FINDINGS" | grep -Fxq -- "$line" 2>/dev/null; then
    return 0
  fi
  if [[ -n "$SCAN_FINDINGS" ]]; then
    SCAN_FINDINGS="${SCAN_FINDINGS}"$'\n'"${line}"
  else
    SCAN_FINDINGS="${line}"
  fi
}

secret_scan__mark_high() {
  SCAN_HAS_HIGH_CONF=1
}

secret_scan__scan_text() {
  local input="$1"
  local out="$1"

  secret_scan_reset

  if printf '%s' "$out" | grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    secret_scan__mark_high
    secret_scan__add_finding "HIGH" "Private key block"
    out="$(printf '%s\n' "$out" | awk '
      BEGIN { in_key=0 }
      /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { if (!in_key) print "[REDACTED PRIVATE KEY BLOCK]"; in_key=1; next }
      /-----END [A-Z ]*PRIVATE KEY-----/ { in_key=0; next }
      { if (!in_key) print }
    ')"
  fi

  if printf '%s' "$out" | grep -Eiq -- 'Bearer[[:space:]]+[A-Za-z0-9._-]{20,}'; then
    secret_scan__mark_high
    secret_scan__add_finding "HIGH" "Bearer token"
  fi
  if printf '%s' "$out" | grep -Eq -- 'AKIA[0-9A-Z]{16}'; then
    secret_scan__mark_high
    secret_scan__add_finding "HIGH" "AWS access key"
  fi
  if printf '%s' "$out" | grep -Eq -- 'gh[pousr]_[A-Za-z0-9]{20,}'; then
    secret_scan__mark_high
    secret_scan__add_finding "HIGH" "GitHub token"
  fi
  if printf '%s' "$out" | grep -Eq -- 'sk-[A-Za-z0-9_-]{20,}'; then
    secret_scan__mark_high
    secret_scan__add_finding "HIGH" "API key-style token"
  fi
  if printf '%s' "$out" | grep -Eiq -- '\beyJ[A-Za-z0-9._-]{10,}\b'; then
    secret_scan__add_finding "LOW" "JWT-like token"
  fi
  if printf '%s' "$out" | grep -Eq -- '\b[A-Fa-f0-9]{32,}\b'; then
    secret_scan__add_finding "LOW" "Long hex token-like string"
  fi
  if printf '%s' "$out" | grep -Eiq -- '([Pp]assword|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][-_ ]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]+'; then
    secret_scan__add_finding "LOW" "Secret assignment value"
  fi

  out="$(printf '%s' "$out" | sed -E \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]{20,}/\1[REDACTED]/g' \
    -e 's/(AKIA[0-9A-Z]{16})/[REDACTED]/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9]{20,})/[REDACTED]/g' \
    -e 's/(sk-[A-Za-z0-9_-]{20,})/[REDACTED]/g' \
    -e 's/\beyJ[A-Za-z0-9._-]{10,}\b/[REDACTED]/g' \
    -e 's/\b[A-Fa-f0-9]{32,}\b/[REDACTED]/g' \
    -e 's/([Pp]assword|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][-_ ]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g')"

  SCAN_REDACTED_TEXT="$out"
}

secret_scan_text_write() {
  local input="$1"
  local allow_redact="${2:-0}"
  secret_scan__scan_text "$input"

  if [[ "$SCAN_HAS_HIGH_CONF" -eq 1 && "$allow_redact" != "1" ]]; then
    SCAN_STATUS="blocked"
    return 3
  fi

  if [[ -n "$SCAN_FINDINGS" ]]; then
    SCAN_STATUS="redacted"
  else
    SCAN_STATUS="pass"
  fi
  return 0
}

secret_scan_text_read() {
  local input="$1"
  secret_scan__scan_text "$input"
  if [[ -n "$SCAN_FINDINGS" ]]; then
    SCAN_STATUS="redacted"
  else
    SCAN_STATUS="pass"
  fi
  return 0
}

secret_scan_file_write() {
  local path="$1"
  local allow_redact="${2:-0}"
  [[ -f "$path" ]] || return 2
  local input
  input="$(cat "$path")"
  secret_scan_text_write "$input" "$allow_redact"
}

secret_scan_file_read() {
  local path="$1"
  [[ -f "$path" ]] || return 2
  local input
  input="$(cat "$path")"
  secret_scan_text_read "$input"
}
