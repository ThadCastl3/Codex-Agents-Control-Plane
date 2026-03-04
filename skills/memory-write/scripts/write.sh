#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"

usage() {
  cat <<'EOF'
Usage:
  write.sh --type <type> --title "<title>" [--body "<text>"] [--project "<name>"] [--status "<status>"] [--next "<items>"] [--tags "<t1,t2>"] [--date YYYY-MM-DD]

Types:
  log | decision | project | knowledge | pattern

Notes:
  - Writes are append-only except index link additions.
  - Secrets are redacted before writing.
  - Memory root defaults to ~/.config/codex-agents/memory (override with MEMORY_ROOT env var).
EOF
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
  if [[ -z "$out" ]]; then
    out="entry"
  fi
  printf '%s' "$out"
}

date_to_epoch() {
  local d="$1"
  if date -j -f "%Y-%m-%d" "$d" "+%s" >/dev/null 2>&1; then
    date -j -f "%Y-%m-%d" "$d" "+%s"
    return 0
  fi
  if date -d "$d" "+%s" >/dev/null 2>&1; then
    date -d "$d" "+%s"
    return 0
  fi
  return 1
}

valid_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date_to_epoch "$1" >/dev/null 2>&1
}

has_fixed() {
  local file="$1"
  local pat="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -Fq -- "$pat" "$file"
  else
    grep -Fq -- "$pat" "$file"
  fi
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

format_list() {
  local text="$1"
  local prefix="$2"
  local out="" line item
  local -a parts=()

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
      out+="${prefix}${item}"$'\n'
    done
  done <<< "$text"

  printf '%s' "$out"
}

REDACTION_NOTES=()
REDACTED_TEXT=""

add_redaction_note() {
  local note="$1"
  local existing
  for existing in "${REDACTION_NOTES[@]:-}"; do
    if [[ "$existing" == "$note" ]]; then
      return 0
    fi
  done
  REDACTION_NOTES+=("$note")
}

redact_text() {
  local txt="$1"
  local out="$1"

  if printf '%s' "$out" | grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    add_redaction_note "Private key block redacted."
    out="$(printf '%s\n' "$out" | awk '
      BEGIN { in_key=0 }
      /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { if (!in_key) print "[REDACTED PRIVATE KEY BLOCK]"; in_key=1; next }
      /-----END [A-Z ]*PRIVATE KEY-----/ { in_key=0; next }
      { if (!in_key) print }
    ')"
  fi

  if printf '%s' "$out" | grep -Eiq -- 'Bearer[[:space:]]+[A-Za-z0-9._-]+'; then
    add_redaction_note "Bearer token redacted."
  fi
  if printf '%s' "$out" | grep -Eq -- 'AKIA[0-9A-Z]{16}'; then
    add_redaction_note "AWS access key redacted."
  fi
  if printf '%s' "$out" | grep -Eq -- 'gh[pousr]_[A-Za-z0-9]{20,}'; then
    add_redaction_note "GitHub token redacted."
  fi
  if printf '%s' "$out" | grep -Eq -- 'sk-[A-Za-z0-9]{20,}'; then
    add_redaction_note "API key-style token redacted."
  fi
  if printf '%s' "$out" | grep -Eiq -- '\beyJ[A-Za-z0-9._-]{10,}\b'; then
    add_redaction_note "JWT-like token redacted."
  fi
  if printf '%s' "$out" | grep -Eiq -- '([Pp]assword|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][-_ ]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]+'; then
    add_redaction_note "Secret assignment value redacted."
  fi

  out="$(printf '%s' "$out" | sed -E \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/(AKIA[0-9A-Z]{16})/[REDACTED]/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9]{20,})/[REDACTED]/g' \
    -e 's/(sk-[A-Za-z0-9]{20,})/[REDACTED]/g' \
    -e 's/\beyJ[A-Za-z0-9._-]{10,}\b/[REDACTED]/g' \
    -e 's/\b[A-Fa-f0-9]{32,}\b/[REDACTED]/g' \
    -e 's/([Pp]assword|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][-_ ]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g')"

  REDACTED_TEXT="$out"
}

sanitize_into() {
  local target_var="$1"
  local name="$2"
  local raw="$3"
  local out

  redact_text "$raw"
  out="$REDACTED_TEXT"
  if [[ "$out" != "$raw" ]]; then
    add_redaction_note "Sensitive content redacted in field: ${name}."
  fi
  printf -v "$target_var" '%s' "$out"
}

ensure_memory_layout() {
  local root="$1"
  mkdir -p "$root"/logs "$root"/decisions "$root"/projects "$root"/knowledge "$root"/patterns
  if [[ ! -f "$root/index.md" ]]; then
    cat > "$root/index.md" <<'EOF'
# Agent Memory Index

This directory stores persistent operational knowledge.

Categories:

logs/
  chronological system observations

decisions/
  architecture and workflow decisions

projects/
  ongoing initiatives

knowledge/
  general facts and references

patterns/
  reusable engineering patterns
EOF
  fi
}

WRITE_REPORTS=()
SUMMARY=""

record_write() {
  local path="$1"
  local action="$2"
  WRITE_REPORTS+=("${path}|${action}")
}

append_index_link_if_missing() {
  local rel_path="$1"
  local label="$2"
  local index_file="$MEMORY_ROOT/index.md"

  if has_fixed "$index_file" "$rel_path"; then
    return 0
  fi

  if ! has_fixed "$index_file" "## Entries"; then
    printf "\n## Entries\n" >> "$index_file"
  fi

  printf -- "- [%s](%s) - %s\n" "$rel_path" "$rel_path" "$label" >> "$index_file"
  record_write "$index_file" "appended (index link)"
}

entry_type=""
title=""
body=""
project=""
status=""
next_items=""
tags=""
entry_date=""

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || die "missing value for --type"
      entry_type="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || die "missing value for --title"
      title="$2"
      shift 2
      ;;
    --body)
      [[ $# -ge 2 ]] || die "missing value for --body"
      body="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "missing value for --project"
      project="$2"
      shift 2
      ;;
    --status)
      [[ $# -ge 2 ]] || die "missing value for --status"
      status="$2"
      shift 2
      ;;
    --next)
      [[ $# -ge 2 ]] || die "missing value for --next"
      next_items="$2"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$entry_type" in
  log|decision|project|knowledge|pattern) ;;
  *) die "--type must be one of: log, decision, project, knowledge, pattern" ;;
esac

title="$(trim "$title")"
[[ -n "$title" ]] || die "--title is required"

if [[ -z "$entry_date" ]]; then
  entry_date="$(date "+%Y-%m-%d")"
fi
if ! valid_date "$entry_date"; then
  die "--date must be valid YYYY-MM-DD"
fi

entry_time="$(date "+%H:%M")"
timestamp="${entry_date} ${entry_time}"
year="${entry_date%%-*}"
month_day="$(printf '%s' "$entry_date" | cut -c6-10)"
year_month="$(printf '%s' "$entry_date" | cut -c1-7)"

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
ensure_memory_layout "$MEMORY_ROOT"

sanitize_into title "title" "$title"
sanitize_into body "body" "$body"
sanitize_into project "project" "$project"
sanitize_into status "status" "$status"
sanitize_into next_items "next" "$next_items"
sanitize_into tags "tags" "$tags"
tags="$(normalize_tags "$tags")"

write_log() {
  local file="$MEMORY_ROOT/logs/$year/$month_day.md"
  local notes
  mkdir -p "$(dirname "$file")"

  if [[ -f "$file" ]]; then
    record_write "$file" "appended"
  else
    : > "$file"
    record_write "$file" "created + appended"
  fi

  printf "## %s — %s\n" "$timestamp" "$title" >> "$file"
  notes="$(format_list "$body" "- ")"
  if [[ -n "$notes" ]]; then
    printf "%s\n" "$notes" >> "$file"
  else
    printf -- "- (no additional notes)\n" >> "$file"
  fi
  if [[ -n "$tags" ]]; then
    printf "Tags: %s\n" "$tags" >> "$file"
  fi
  printf "\n" >> "$file"

  SUMMARY="Appended a log entry to $file."
}

write_decision() {
  local slug file notes n
  slug="$(slugify "$title")"
  file="$MEMORY_ROOT/decisions/${year_month}-${slug}.md"
  n=2
  while [[ -e "$file" ]]; do
    file="$MEMORY_ROOT/decisions/${year_month}-${slug}-$(printf '%02d' "$n").md"
    n=$((n + 1))
  done

  notes="$(format_list "$body" "- ")"
  if [[ -z "$notes" ]]; then
    notes="- (fill in decision details)"
  fi

  {
    printf "# %s\n\n" "$title"
    printf "Date: %s\n" "$entry_date"
    printf "Status: accepted\n"
    if [[ -n "$tags" ]]; then
      printf "Tags: %s\n" "$tags"
    fi
    printf "\n## Context\n"
    printf -- "- Decision captured on %s.\n\n" "$entry_date"
    printf "## Decision\n"
    printf "%s\n" "$notes"
    printf "\n## Consequences\n"
    printf -- "- TBD\n\n"
    printf "## Tradeoffs\n"
    printf -- "- TBD\n\n"
    printf "## Follow-ups\n"
    printf -- "- [ ] TBD\n"
  } > "$file"

  record_write "$file" "created"
  SUMMARY="Created a decision record with one-decision-per-file semantics."
}

write_project() {
  local project_slug project_dir overview log_file notes next_block rel_overview
  project="$(trim "$project")"
  [[ -n "$project" ]] || die "--project is required for type=project"

  project_slug="$(slugify "$project")"
  project_dir="$MEMORY_ROOT/projects/$project_slug"
  overview="$project_dir/overview.md"
  log_file="$project_dir/log.md"
  rel_overview="projects/$project_slug/overview.md"

  mkdir -p "$project_dir"
  if [[ ! -f "$overview" ]]; then
    {
      printf "# %s\n\n" "$project"
      printf "Owner:\n"
      printf "Goal:\n"
      printf "Constraints:\n"
    } > "$overview"
    record_write "$overview" "created"
    append_index_link_if_missing "$rel_overview" "Project: $project"
  fi

  if [[ -f "$log_file" ]]; then
    record_write "$log_file" "appended"
  else
    : > "$log_file"
    record_write "$log_file" "created + appended"
  fi

  notes="$(format_list "$body" "- ")"
  next_block="$(format_list "$next_items" "- [ ] ")"
  [[ -z "$status" ]] && status="unspecified"

  printf "## %s — %s\n" "$timestamp" "$title" >> "$log_file"
  printf "Status: %s\n" "$status" >> "$log_file"
  printf "Notes:\n" >> "$log_file"
  if [[ -n "$notes" ]]; then
    printf "%s\n" "$notes" >> "$log_file"
  else
    printf -- "- (no additional notes)\n" >> "$log_file"
  fi
  printf "Next:\n" >> "$log_file"
  if [[ -n "$next_block" ]]; then
    printf "%s\n" "$next_block" >> "$log_file"
  else
    printf -- "- [ ] (no next actions captured)\n" >> "$log_file"
  fi
  if [[ -n "$tags" ]]; then
    printf "Tags: %s\n" "$tags" >> "$log_file"
  fi
  printf "\n" >> "$log_file"

  SUMMARY="Updated project state and appended next actions in $log_file."
}

write_knowledge() {
  local slug file rel_file
  slug="$(slugify "$title")"
  file="$MEMORY_ROOT/knowledge/${slug}.md"
  rel_file="knowledge/${slug}.md"

  if [[ ! -f "$file" ]]; then
    {
      printf "# %s\n\n" "$title"
      printf "Date: %s\n" "$entry_date"
      if [[ -n "$tags" ]]; then
        printf "Tags: %s\n" "$tags"
      fi
      printf "\n"
      if [[ -n "$body" ]]; then
        printf "%s\n" "$body"
      else
        printf "(add stable reference notes)\n"
      fi
    } > "$file"
    record_write "$file" "created"
    append_index_link_if_missing "$rel_file" "$title"
    SUMMARY="Created a stable knowledge note."
    return
  fi

  {
    printf "\n## %s — Update\n" "$timestamp"
    if [[ -n "$body" ]]; then
      printf "%s\n" "$body"
    else
      printf "(no additional content)\n"
    fi
    if [[ -n "$tags" ]]; then
      printf "Tags: %s\n" "$tags"
    fi
  } >> "$file"
  record_write "$file" "appended"
  SUMMARY="Appended an update to existing knowledge note."
}

write_pattern() {
  local slug file rel_file notes
  slug="$(slugify "$title")"
  file="$MEMORY_ROOT/patterns/${slug}.md"
  rel_file="patterns/${slug}.md"
  notes="$(format_list "$body" "- ")"

  if [[ ! -f "$file" ]]; then
    {
      printf "# %s\n\n" "$title"
      printf "Date: %s\n" "$entry_date"
      if [[ -n "$tags" ]]; then
        printf "Tags: %s\n" "$tags"
      fi
      printf "\n## When to use\n"
      printf -- "- TBD\n\n"
      printf "## Steps\n"
      printf -- "- TBD\n\n"
      printf "## Verification\n"
      printf -- "- TBD\n\n"
      printf "## Failure modes\n"
      printf -- "- TBD\n\n"
      printf "## Notes\n"
      if [[ -n "$notes" ]]; then
        printf "%s\n" "$notes"
      else
        printf -- "- (add reusable guidance)\n"
      fi
    } > "$file"
    record_write "$file" "created"
    append_index_link_if_missing "$rel_file" "$title"
    SUMMARY="Created a reusable pattern/runbook template."
    return
  fi

  {
    printf "\n## %s — Update\n" "$timestamp"
    if [[ -n "$notes" ]]; then
      printf "%s\n" "$notes"
    else
      printf -- "- (no additional notes)\n"
    fi
    if [[ -n "$tags" ]]; then
      printf "Tags: %s\n" "$tags"
    fi
  } >> "$file"
  record_write "$file" "appended"
  SUMMARY="Appended an update to an existing reusable pattern."
}

case "$entry_type" in
  log) write_log ;;
  decision) write_decision ;;
  project) write_project ;;
  knowledge) write_knowledge ;;
  pattern) write_pattern ;;
esac

echo "## Memory Write Report"
echo "- Type: \`$entry_type\`"
echo "- Title: \`$title\`"
echo "- Timestamp: \`$timestamp\`"
echo "- Memory root: \`$MEMORY_ROOT\`"
echo
echo "## Files Written"

idx=1
for item in "${WRITE_REPORTS[@]:-}"; do
  path="${item%%|*}"
  action="${item##*|}"
  echo "${idx}) \`${path}\` (${action})"
  idx=$((idx + 1))
done

echo
echo "## Summary"
echo "- $SUMMARY"

echo
echo "## Redactions"
if [[ "${#REDACTION_NOTES[@]}" -eq 0 ]]; then
  echo "- None"
else
  for note in "${REDACTION_NOTES[@]}"; do
    echo "- ${note}"
  done
  echo "- Recommendation: store secrets in environment variables or a secret manager."
fi
