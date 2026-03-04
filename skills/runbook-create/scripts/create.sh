#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/lib/secret_scan.sh"

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"

usage() {
  cat <<'USAGE'
Usage:
  create.sh --title "<title>" --when-to-use "<text>" --steps "<items>" --verification "<items>" --failure-modes "<items>" [--notes "<text>"] [--tags "t1,t2"] [--date YYYY-MM-DD] [--allow-redact]
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 2
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

slugify() {
  local in out
  in="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  out="$(printf '%s' "$in" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$out" ]] || out="pattern"
  printf '%s' "$out"
}

valid_date() {
  local d="$1"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  if date -j -f "%Y-%m-%d" "$d" "+%s" >/dev/null 2>&1; then
    return 0
  fi
  if date -d "$d" "+%s" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

REDACTION_NOTES=()
ALLOW_REDACT=0

add_redaction_note() {
  local note="$1"
  local existing
  for existing in "${REDACTION_NOTES[@]:-}"; do
    [[ "$existing" == "$note" ]] && return 0
  done
  REDACTION_NOTES+=("$note")
}

append_scan_findings() {
  if [[ -z "$SCAN_FINDINGS" ]]; then
    return 0
  fi
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -n "$f" ]] || continue
    add_redaction_note "$f"
  done <<< "$SCAN_FINDINGS"
}

sanitize_into() {
  local target_var="$1"
  local field_name="$2"
  local raw="$3"
  local out rc=0

  if secret_scan_text_write "$raw" "$ALLOW_REDACT"; then
    :
  else
    rc=$?
    if [[ "$rc" -eq 3 ]]; then
      echo "Error: high-confidence secret detected in field: $field_name" >&2
      if [[ -n "$SCAN_FINDINGS" ]]; then
        while IFS= read -r f || [[ -n "$f" ]]; do
          [[ -n "$f" ]] || continue
          echo " - $f" >&2
        done <<< "$SCAN_FINDINGS"
      fi
      echo "Re-run with --allow-redact to continue with redacted values." >&2
      exit 3
    fi
    die "secret scan failed for field: $field_name"
  fi

  out="$SCAN_REDACTED_TEXT"
  append_scan_findings
  if [[ "$out" != "$raw" ]]; then
    add_redaction_note "Sensitive content redacted in field: ${field_name}."
  fi
  printf -v "$target_var" '%s' "$out"
}

normalize_tags() {
  local raw="$1"
  local line item out=""
  local seen_file
  local -a parts=()
  seen_file="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    parts=()
    IFS=',' read -r -a parts <<< "$line"
    for item in "${parts[@]:-}"; do
      item="$(trim "$item")"
      [[ -z "$item" ]] && continue
      if grep -Fxiq -- "$item" "$seen_file" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$item" >> "$seen_file"
      if [[ -z "$out" ]]; then
        out="$item"
      else
        out="$out, $item"
      fi
    done
  done <<< "$raw"

  rm -f "$seen_file"
  printf '%s' "$out"
}

parse_items_to_file() {
  local text="$1"
  local out_file="$2"
  local line item
  local -a parts=()
  local seen_file

  seen_file="$(mktemp)"
  : > "$out_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    line="${line#- }"
    line="$(printf '%s' "$line" | sed -E 's/^\[[ xX]\][[:space:]]*//')"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue

    parts=()
    IFS=',' read -r -a parts <<< "$line"
    for item in "${parts[@]:-}"; do
      item="$(trim "$item")"
      [[ -z "$item" ]] && continue
      if grep -Fxiq -- "$item" "$seen_file" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$item" >> "$seen_file"
      printf '%s\n' "$item" >> "$out_file"
    done
  done <<< "$text"

  rm -f "$seen_file"
}

first_nonempty_line() {
  local text="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    printf '%s' "$line"
    return 0
  done <<< "$text"
  printf '%s' ""
}

title=""
when_to_use=""
steps=""
verification=""
failure_modes=""
notes=""
tags=""
entry_date=""

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ $# -ge 2 ]] || die "missing value for --title"
      title="$2"
      shift 2
      ;;
    --when-to-use)
      [[ $# -ge 2 ]] || die "missing value for --when-to-use"
      when_to_use="$2"
      shift 2
      ;;
    --steps)
      [[ $# -ge 2 ]] || die "missing value for --steps"
      steps="$2"
      shift 2
      ;;
    --verification)
      [[ $# -ge 2 ]] || die "missing value for --verification"
      verification="$2"
      shift 2
      ;;
    --failure-modes)
      [[ $# -ge 2 ]] || die "missing value for --failure-modes"
      failure_modes="$2"
      shift 2
      ;;
    --notes)
      [[ $# -ge 2 ]] || die "missing value for --notes"
      notes="$2"
      shift 2
      ;;
    --tags)
      [[ $# -ge 2 ]] || die "missing value for --tags"
      tags="$2"
      shift 2
      ;;
    --date)
      [[ $# -ge 2 ]] || die "missing value for --date"
      entry_date="$2"
      shift 2
      ;;
    --allow-redact)
      ALLOW_REDACT=1
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

title="$(trim "$title")"
when_to_use="$(trim "$when_to_use")"
steps="$(trim "$steps")"
verification="$(trim "$verification")"
failure_modes="$(trim "$failure_modes")"
notes="$(trim "$notes")"
tags="$(trim "$tags")"

[[ -n "$title" ]] || die "--title is required"
[[ -n "$when_to_use" ]] || die "--when-to-use is required"
[[ -n "$steps" ]] || die "--steps is required"
[[ -n "$verification" ]] || die "--verification is required"
[[ -n "$failure_modes" ]] || die "--failure-modes is required"

if [[ -z "$entry_date" ]]; then
  entry_date="$(date "+%Y-%m-%d")"
fi
valid_date "$entry_date" || die "--date must be valid YYYY-MM-DD"

sanitize_into title "title" "$title"
sanitize_into when_to_use "when-to-use" "$when_to_use"
sanitize_into steps "steps" "$steps"
sanitize_into verification "verification" "$verification"
sanitize_into failure_modes "failure-modes" "$failure_modes"
sanitize_into notes "notes" "$notes"
sanitize_into tags "tags" "$tags"

tags="$(normalize_tags "$tags")"

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
PATTERNS_DIR="$MEMORY_ROOT/patterns"
mkdir -p "$PATTERNS_DIR"

steps_file="$(mktemp)"
verification_file="$(mktemp)"
failure_file="$(mktemp)"
trap 'rm -f "$steps_file" "$verification_file" "$failure_file"' EXIT

parse_items_to_file "$steps" "$steps_file"
parse_items_to_file "$verification" "$verification_file"
parse_items_to_file "$failure_modes" "$failure_file"

steps_count="$(wc -l < "$steps_file" | tr -d ' ')"
verification_count="$(wc -l < "$verification_file" | tr -d ' ')"
failure_count="$(wc -l < "$failure_file" | tr -d ' ')"

(( steps_count > 0 )) || die "--steps must contain at least one non-empty item"
(( verification_count > 0 )) || die "--verification must contain at least one non-empty item"
(( failure_count > 0 )) || die "--failure-modes must contain at least one non-empty item"

slug="$(slugify "$title")"
filename="${slug}.md"
rel_path="patterns/${filename}"
path="$MEMORY_ROOT/$rel_path"

suffix=2
while [[ -e "$path" ]]; do
  filename="${slug}-${suffix}.md"
  rel_path="patterns/${filename}"
  path="$MEMORY_ROOT/$rel_path"
  suffix=$((suffix + 1))
done

{
  printf "# %s\n\n" "$title"
  printf "Date: %s\n" "$entry_date"
  if [[ -n "$tags" ]]; then
    printf "Tags: %s\n" "$tags"
  fi
  printf "\n"

  printf "## When to use\n"
  printf "%s\n\n" "$when_to_use"

  printf "## Steps\n"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf -- "- %s\n" "$line"
  done < "$steps_file"
  printf "\n"

  printf "## Verification\n"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf -- "- %s\n" "$line"
  done < "$verification_file"
  printf "\n"

  printf "## Failure modes\n"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf -- "- %s\n" "$line"
  done < "$failure_file"

  if [[ -n "$notes" ]]; then
    printf "\n## Notes\n"
    printf "%s\n" "$notes"
  fi
} > "$path"

description="$(first_nonempty_line "$when_to_use")"
if [[ -z "$description" ]]; then
  description="Pattern runbook"
fi

index_script="$REPO_ROOT/skills/memory-index-update/scripts/update_index.sh"
[[ -x "$index_script" ]] || die "memory-index-update script missing or not executable: $index_script"

index_args=(
  --change add-pattern
  --path "$rel_path"
  --description "$description"
  --title "$title"
)
if [[ "$ALLOW_REDACT" -eq 1 ]]; then
  index_args+=(--allow-redact)
fi

index_output=""
if ! index_output="$(MEMORY_ROOT="$MEMORY_ROOT" "$index_script" "${index_args[@]}" 2>&1)"; then
  echo "$index_output" >&2
  echo "Error: failed to update memory index for runbook." >&2
  exit 1
fi

index_status="$(printf '%s\n' "$index_output" | sed -nE 's/^- Status: `([^`]+)`/\1/p' | head -n1)"
[[ -n "$index_status" ]] || index_status="unknown"

echo "## Runbook Create Report"
echo

echo "## Files"
echo "- Created: \`$rel_path\`"

echo
echo "## Entry"
echo "- Heading: \`# $title\`"
echo "- Index update: \`$index_status\`"

echo
echo "## Warnings"
if [[ "${#REDACTION_NOTES[@]}" -eq 0 ]]; then
  echo "- None"
else
  for w in "${REDACTION_NOTES[@]}"; do
    echo "- $w"
  done
  echo "- Recommendation: store secrets in environment variables or a secret manager."
fi
