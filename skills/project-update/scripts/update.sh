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
  update.sh --project "<project>" --title "<title>" --status "<status>" --notes "<text>" --next "<items>" [--blockers "<items>"] [--tags "t1,t2"] [--date YYYY-MM-DD] [--time HH:MM] [--allow-redact]

Notes:
  - Appends exactly one structured log entry.
  - Creates project scaffolding (overview.md/log.md) if missing.
  - Never rewrites or reorders existing log entries.
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
  [[ -n "$out" ]] || out="project"
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

valid_time() {
  local t="$1"
  [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
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

resolve_project_dir() {
  local input_name="$1"
  local projects_dir="$2"
  local input_slug base base_slug

  RESOLVED_PROJECT=""
  PROJECT_DIR=""

  if [[ -d "$projects_dir/$input_name" ]]; then
    RESOLVED_PROJECT="$input_name"
    PROJECT_DIR="$projects_dir/$input_name"
    return 0
  fi

  input_slug="$(slugify "$input_name")"
  if [[ -d "$projects_dir/$input_slug" ]]; then
    RESOLVED_PROJECT="$input_slug"
    PROJECT_DIR="$projects_dir/$input_slug"
    return 0
  fi

  while IFS= read -r d || [[ -n "$d" ]]; do
    [[ -n "$d" ]] || continue
    base="$(basename "$d")"
    base_slug="$(slugify "$base")"
    if [[ "$base_slug" == "$input_slug" ]]; then
      RESOLVED_PROJECT="$base"
      PROJECT_DIR="$d"
      return 0
    fi
  done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d | sort)

  RESOLVED_PROJECT="$input_slug"
  PROJECT_DIR="$projects_dir/$RESOLVED_PROJECT"
  return 0
}

project=""
title=""
status=""
notes=""
next_items=""
blockers=""
tags=""
entry_date=""
entry_time=""

has_project=0
has_title=0
has_status=0
has_notes=0
has_next=0

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "missing value for --project"
      project="$2"
      has_project=1
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || die "missing value for --title"
      title="$2"
      has_title=1
      shift 2
      ;;
    --status)
      [[ $# -ge 2 ]] || die "missing value for --status"
      status="$2"
      has_status=1
      shift 2
      ;;
    --notes)
      [[ $# -ge 2 ]] || die "missing value for --notes"
      notes="$2"
      has_notes=1
      shift 2
      ;;
    --next)
      [[ $# -ge 2 ]] || die "missing value for --next"
      next_items="$2"
      has_next=1
      shift 2
      ;;
    --blockers)
      [[ $# -ge 2 ]] || die "missing value for --blockers"
      blockers="$2"
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
    --time)
      [[ $# -ge 2 ]] || die "missing value for --time"
      entry_time="$2"
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

[[ "$has_project" -eq 1 ]] || die "--project is required"
[[ "$has_title" -eq 1 ]] || die "--title is required"
[[ "$has_status" -eq 1 ]] || die "--status is required"
[[ "$has_notes" -eq 1 ]] || die "--notes is required"
[[ "$has_next" -eq 1 ]] || die "--next is required"

project="$(trim "$project")"
title="$(trim "$title")"
status="$(trim "$status")"
notes="$(trim "$notes")"
next_items="$(trim "$next_items")"
blockers="$(trim "$blockers")"
tags="$(trim "$tags")"

[[ -n "$project" ]] || die "--project must be non-empty"
[[ -n "$title" ]] || die "--title must be non-empty"
[[ -n "$status" ]] || die "--status must be non-empty"
[[ -n "$notes" ]] || die "--notes must be non-empty"
[[ -n "$next_items" ]] || die "--next must be non-empty"

if [[ "$project" == /* || "$project" == *".."* ]]; then
  die "--project must be a project identifier, not a path"
fi

if [[ -z "$entry_date" ]]; then
  entry_date="$(date "+%Y-%m-%d")"
fi
if [[ -z "$entry_time" ]]; then
  entry_time="$(date "+%H:%M")"
fi

valid_date "$entry_date" || die "--date must be valid YYYY-MM-DD"
valid_time "$entry_time" || die "--time must be valid HH:MM (24h)"

sanitize_into project "project" "$project"
sanitize_into title "title" "$title"
sanitize_into status "status" "$status"
sanitize_into notes "notes" "$notes"
sanitize_into next_items "next" "$next_items"
sanitize_into blockers "blockers" "$blockers"
sanitize_into tags "tags" "$tags"

tags="$(normalize_tags "$tags")"

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
PROJECTS_DIR="$MEMORY_ROOT/projects"
mkdir -p "$PROJECTS_DIR"

resolve_project_dir "$project" "$PROJECTS_DIR"
mkdir -p "$PROJECT_DIR"

overview_file="$PROJECT_DIR/overview.md"
log_file="$PROJECT_DIR/log.md"
rel_overview="projects/${RESOLVED_PROJECT}/overview.md"
rel_log="projects/${RESOLVED_PROJECT}/log.md"
index_status="not-required"
index_manual_command=""

created_files=()
if [[ ! -f "$overview_file" ]]; then
  {
    printf "# %s\n\n" "$RESOLVED_PROJECT"
    printf "Goal:\n"
    printf "Constraints:\n"
    printf "Approach:\n"
    printf "Key Links:\n"
  } > "$overview_file"
  created_files+=("$rel_overview")

  index_script="$REPO_ROOT/skills/memory-index-update/scripts/update_index.sh"
  index_desc="Project continuity hub for ${RESOLVED_PROJECT}."
  index_args=(
    --change add-project
    --path "$rel_overview"
    --description "$index_desc"
    --title "$RESOLVED_PROJECT"
  )
  if [[ "$ALLOW_REDACT" -eq 1 ]]; then
    index_args+=(--allow-redact)
  fi

  printf -v index_manual_command \
    'MEMORY_ROOT=%q %q --change add-project --path %q --description %q --title %q' \
    "$MEMORY_ROOT" "$index_script" "$rel_overview" "$index_desc" "$RESOLVED_PROJECT"
  if [[ "$ALLOW_REDACT" -eq 1 ]]; then
    index_manual_command="$index_manual_command --allow-redact"
  fi

  if [[ -x "$index_script" ]]; then
    index_output=""
    if index_output="$(MEMORY_ROOT="$MEMORY_ROOT" "$index_script" "${index_args[@]}" 2>&1)"; then
      index_status="$(printf '%s\n' "$index_output" | sed -nE 's/^- Status: `([^`]+)`/\1/p' | head -n1)"
      [[ -n "$index_status" ]] || index_status="unknown"
    else
      index_status="manual-required"
    fi
  else
    index_status="manual-required"
  fi
fi

if [[ ! -f "$log_file" ]]; then
  : > "$log_file"
  created_files+=("$rel_log")
fi

notes_items_file="$(mktemp)"
next_items_file="$(mktemp)"
blockers_items_file="$(mktemp)"
trap 'rm -f "$notes_items_file" "$next_items_file" "$blockers_items_file"' EXIT

parse_items_to_file "$notes" "$notes_items_file"
parse_items_to_file "$next_items" "$next_items_file"
parse_items_to_file "$blockers" "$blockers_items_file"

notes_count="$(wc -l < "$notes_items_file" | tr -d ' ')"
next_count="$(wc -l < "$next_items_file" | tr -d ' ')"

(( notes_count > 0 )) || die "--notes must contain at least one non-empty item"
(( next_count > 0 )) || die "--next must contain at least one non-empty item"

entry_heading="## ${entry_date} ${entry_time} — ${title}"

{
  printf "%s\n" "$entry_heading"
  printf "Status: %s\n" "$status"
  if [[ -n "$tags" ]]; then
    printf "Tags: %s\n" "$tags"
  fi
  printf "Notes:\n"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf -- "- %s\n" "$line"
  done < "$notes_items_file"
  printf "Next:\n"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf -- "- [ ] %s\n" "$line"
  done < "$next_items_file"
  if [[ -s "$blockers_items_file" ]]; then
    printf "Blockers:\n"
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf -- "- %s\n" "$line"
    done < "$blockers_items_file"
  fi
  printf "\n"
} >> "$log_file"

echo "## Project Update Report"
echo

echo "## Files"
echo "- Updated: \`$rel_log\`"
if [[ "${#created_files[@]}" -eq 0 ]]; then
  echo "- Created: None"
else
  for cf in "${created_files[@]}"; do
    echo "- Created: \`$cf\`"
  done
fi

echo
echo "## Entry"
echo "- Heading: \`$entry_heading\`"
echo "- Notes items: \`$notes_count\`"
echo "- Next items: \`$next_count\`"
echo "- Project index update: \`$index_status\`"

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
if [[ "$index_status" == "manual-required" ]]; then
  echo "- Project index update could not be completed automatically."
  echo "- Run: \`$index_manual_command\`"
fi
