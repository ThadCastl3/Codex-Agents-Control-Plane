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
  record.sh --title "<title>" --decision "<one sentence>" --context "<bullets>" --why "<bullets>" --tradeoffs "<bullets>" --followups "<items>" [--supersedes "<path>"] [--status accepted|proposed|deprecated] [--tags "t1,t2"] [--date YYYY-MM-DD] [--allow-redact]

Notes:
  - Creates exactly one new file under memory/decisions/.
  - Existing decision files are never modified.
  - Filename pattern: YYYY-MM-<slug>.md (with -2, -3... suffix on collision).
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
  [[ -n "$out" ]] || out="decision"
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

normalize_tags() {
  local raw="$1"
  local clean="" part
  local -a parts=()
  IFS=',' read -r -a parts <<< "$raw"
  for part in "${parts[@]:-}"; do
    part="$(trim "$part")"
    [[ -z "$part" ]] && continue
    if [[ -z "$clean" ]]; then
      clean="$part"
    else
      clean="$clean, $part"
    fi
  done
  printf '%s' "$clean"
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

to_bullets() {
  local text="$1"
  local line item
  local -a parts=()
  local out=""
  local count=0

  BULLET_RESULT=""
  BULLET_COUNT=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    line="${line#- }"
    line="${line#* [ ] }"
    parts=()
    IFS=',' read -r -a parts <<< "$line"
    for item in "${parts[@]:-}"; do
      item="$(trim "$item")"
      [[ -z "$item" ]] && continue
      out+="- ${item}"$'\n'
      count=$((count + 1))
    done
  done <<< "$text"

  BULLET_RESULT="$out"
  BULLET_COUNT="$count"
}

ensure_dirs() {
  local root="$1"
  mkdir -p "$root/decisions"
}

title=""
decision=""
context=""
why=""
tradeoffs=""
followups=""
supersedes=""
status="accepted"
tags=""
entry_date=""

has_title=0
has_decision=0
has_context=0
has_why=0
has_tradeoffs=0
has_followups=0

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ $# -ge 2 ]] || die "missing value for --title"
      title="$2"
      has_title=1
      shift 2
      ;;
    --decision)
      [[ $# -ge 2 ]] || die "missing value for --decision"
      decision="$2"
      has_decision=1
      shift 2
      ;;
    --context)
      [[ $# -ge 2 ]] || die "missing value for --context"
      context="$2"
      has_context=1
      shift 2
      ;;
    --why)
      [[ $# -ge 2 ]] || die "missing value for --why"
      why="$2"
      has_why=1
      shift 2
      ;;
    --tradeoffs)
      [[ $# -ge 2 ]] || die "missing value for --tradeoffs"
      tradeoffs="$2"
      has_tradeoffs=1
      shift 2
      ;;
    --followups)
      [[ $# -ge 2 ]] || die "missing value for --followups"
      followups="$2"
      has_followups=1
      shift 2
      ;;
    --supersedes)
      [[ $# -ge 2 ]] || die "missing value for --supersedes"
      supersedes="$2"
      shift 2
      ;;
    --status)
      [[ $# -ge 2 ]] || die "missing value for --status"
      status="$2"
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

[[ "$has_title" -eq 1 ]] || die "--title is required"
[[ "$has_decision" -eq 1 ]] || die "--decision is required"
[[ "$has_context" -eq 1 ]] || die "--context is required"
[[ "$has_why" -eq 1 ]] || die "--why is required"
[[ "$has_tradeoffs" -eq 1 ]] || die "--tradeoffs is required"
[[ "$has_followups" -eq 1 ]] || die "--followups is required (can be empty)"

title="$(trim "$title")"
decision="$(trim "$decision")"
context="$(trim "$context")"
why="$(trim "$why")"
tradeoffs="$(trim "$tradeoffs")"
supersedes="$(trim "$supersedes")"
status="$(trim "$status")"
tags="$(normalize_tags "$tags")"

[[ -n "$title" ]] || die "--title must be non-empty"
[[ -n "$decision" ]] || die "--decision must be non-empty"
[[ -n "$context" ]] || die "--context must be non-empty"
[[ -n "$why" ]] || die "--why must be non-empty"
[[ -n "$tradeoffs" ]] || die "--tradeoffs must be non-empty"

case "$status" in
  accepted|proposed|deprecated) ;;
  *) die "--status must be one of: accepted, proposed, deprecated" ;;
esac

if [[ -z "$entry_date" ]]; then
  entry_date="$(date "+%Y-%m-%d")"
fi
valid_date "$entry_date" || die "--date must be valid YYYY-MM-DD"

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
ensure_dirs "$MEMORY_ROOT"

sanitize_into title "title" "$title"
sanitize_into decision "decision" "$decision"
sanitize_into context "context" "$context"
sanitize_into why "why" "$why"
sanitize_into tradeoffs "tradeoffs" "$tradeoffs"
sanitize_into followups "followups" "$followups"
sanitize_into supersedes "supersedes" "$supersedes"
sanitize_into tags "tags" "$tags"

if [[ -n "$supersedes" ]]; then
  if [[ "$supersedes" = /* ]]; then
    die "--supersedes must be a relative path under memory root"
  fi
  if [[ "$supersedes" == *"../"* || "$supersedes" == "../"* || "$supersedes" == *"/.." || "$supersedes" == ".." ]]; then
    die "--supersedes may not contain parent traversal"
  fi
  [[ -f "$MEMORY_ROOT/$supersedes" ]] || die "--supersedes target not found: $supersedes"
fi

context_bullets=""
why_bullets=""
tradeoffs_bullets=""
followups_bullets=""
context_count=0
why_count=0
tradeoffs_count=0
followups_count=0

to_bullets "$context"
context_bullets="$BULLET_RESULT"
context_count="$BULLET_COUNT"

to_bullets "$why"
why_bullets="$BULLET_RESULT"
why_count="$BULLET_COUNT"

to_bullets "$tradeoffs"
tradeoffs_bullets="$BULLET_RESULT"
tradeoffs_count="$BULLET_COUNT"

to_bullets "$followups"
followups_bullets="$BULLET_RESULT"
followups_count="$BULLET_COUNT"

(( context_count >= 1 && context_count <= 6 )) || die "--context must contain 1-6 items"
(( why_count >= 1 && why_count <= 6 )) || die "--why must contain 1-6 items"
(( tradeoffs_count >= 1 && tradeoffs_count <= 8 )) || die "--tradeoffs must contain 1-8 items"
(( followups_count >= 0 && followups_count <= 10 )) || die "--followups must contain 0-10 items"

slug="$(slugify "$title")"
year_month="$(printf '%s' "$entry_date" | cut -c1-7)"
rel_path="decisions/${year_month}-${slug}.md"
target_path="$MEMORY_ROOT/$rel_path"

suffix=2
while [[ -e "$target_path" ]]; do
  rel_path="decisions/${year_month}-${slug}-${suffix}.md"
  target_path="$MEMORY_ROOT/$rel_path"
  suffix=$((suffix + 1))
done

{
  printf "# %s\n\n" "$title"
  printf "Date: %s\n" "$entry_date"
  printf "Status: %s\n" "$status"
  if [[ -n "$tags" ]]; then
    printf "Tags: %s\n" "$tags"
  fi
  if [[ -n "$supersedes" ]]; then
    printf "Supersedes: %s\n" "$supersedes"
  fi
  printf "\n## Context\n"
  printf "%s\n" "$context_bullets"
  printf "## Decision\n"
  printf -- "- %s\n\n" "$decision"
  printf "## Why\n"
  printf "%s\n" "$why_bullets"
  printf "## Tradeoffs\n"
  printf "%s\n" "$tradeoffs_bullets"
  printf "## Follow-ups\n"
  if [[ -n "$followups_bullets" ]]; then
    printf "%s" "$followups_bullets"
  else
    printf -- "- (none)\n"
  fi
} > "$target_path"

echo "## Decision Record Report"
echo "- path: \`$rel_path\`"
echo "- summary: \`$decision\`"
if [[ -n "$supersedes" ]]; then
  echo "- links: \`$supersedes\`"
else
  echo "- links: (none)"
fi
echo
echo "## Warnings"
if [[ "${#REDACTION_NOTES[@]}" -eq 0 ]]; then
  echo "- none"
else
  for note in "${REDACTION_NOTES[@]}"; do
    echo "- $note"
  done
fi
