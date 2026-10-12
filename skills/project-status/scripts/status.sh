#!/usr/bin/env bash
set -euo pipefail

# Buffer and sanitize complete output; scan sources before selecting excerpts.
SECRET_READER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_READER_REPO_ROOT="$(cd "$SECRET_READER_SCRIPT_DIR/../../.." && pwd)"
source "$SECRET_READER_REPO_ROOT/lib/secret_scan.sh"

secret_scan_reader_main() {

export LC_ALL=C

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"

usage() {
  cat <<'EOF'
Usage:
  status.sh "<project>" [--since YYYY-MM-DD] [--max-updates N]

Options:
  --since         Prefer log entries on/after this date
  --max-updates   Maximum recent updates to include (default 5, hard cap 10)
  -h, --help      Show this help
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

date_to_epoch() {
  local d="$1"
  if date -j -f "%Y-%m-%d" "$d" "+%s" >/dev/null 2>&1; then
    date -j -f "%Y-%m-%d" "$d" "+%s"
  else
    date -d "$d" "+%s"
  fi
}

redact_inline() {
  secret_scan_filter_read
}

append_unique_line() {
  local file="$1"
  local line="$2"
  [[ -n "$line" ]] || return 0
  if [[ -f "$file" ]] && grep -Fxq -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$file"
}

extract_heading_block() {
  local file="$1"
  local heading_regex="$2"
  awk -v pat="$heading_regex" '
    function ltrim(s){ sub(/^[ \t]+/, "", s); return s }
    function rtrim(s){ sub(/[ \t]+$/, "", s); return s }
    function trim(s){ return rtrim(ltrim(s)) }
    {
      line=$0
      lower=tolower(line)
      if (lower ~ /^#{1,6}[[:space:]]/) {
        if (in_sec && lower !~ pat) exit
        in_sec = (lower ~ pat)
        next
      }
      if (in_sec) print trim(line)
    }
  ' < <(secret_scan_filter_file_read "$file")
}

extract_first_lines_fallback() {
  local file="$1"
  secret_scan_filter_file_read "$file" | sed -n '1,20p' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ +| +$//g' | awk 'NF>0'
}

collect_list_items() {
  local input="$1"
  local out_file="$2"
  local skip_none="${3:-0}"
  local skip_completed="${4:-0}"
  local line item
  local -a parts=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    line="${line#- }"
    if [[ "$skip_completed" == "1" && "$line" =~ ^\[[xX]\]([[:space:]]|$) ]]; then
      continue
    fi
    parts=()
    IFS=',' read -r -a parts <<< "$line"
    for item in "${parts[@]:-}"; do
      item="$(trim "$item")"
      [[ -z "$item" ]] && continue
      item="$(printf '%s' "$item" | sed -E 's/^\[[ xX]\][[:space:]]*//')"
      item="$(trim "$item")"
      [[ -z "$item" ]] && continue
      if [[ "$skip_none" == "1" ]]; then
        low="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
        case "$low" in
          none|n/a|na|nil|no\ blockers|no\ blocker|none\ noted|no\ known\ blockers) continue ;;
        esac
      fi
      item="$(printf '%s' "$item" | redact_inline)"
      append_unique_line "$out_file" "$item"
    done
  done <<< "$input"
}

project_input=""
since=""
max_updates=5

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

project_input="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      [[ $# -ge 2 ]] || die "missing value for --since"
      since="$2"
      shift 2
      ;;
    --max-updates)
      [[ $# -ge 2 ]] || die "missing value for --max-updates"
      max_updates="$2"
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

project_input="$(trim "$project_input")"
[[ -n "$project_input" ]] || die "project must be non-empty"
[[ "$max_updates" =~ ^[0-9]+$ ]] || die "--max-updates must be an integer"
(( max_updates >= 1 )) || die "--max-updates must be >= 1"
(( max_updates <= 10 )) || max_updates=10

since_epoch=""
if [[ -n "$since" ]]; then
  valid_date "$since" || die "--since must be valid YYYY-MM-DD"
  since_epoch="$(date_to_epoch "$since")"
fi

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
PROJECTS_DIR="$MEMORY_ROOT/projects"
[[ -d "$PROJECTS_DIR" ]] || die "projects directory not found: $PROJECTS_DIR"

resolved_project=""
project_dir=""

# 1) exact folder match
if [[ -d "$PROJECTS_DIR/$project_input" ]]; then
  resolved_project="$project_input"
  project_dir="$PROJECTS_DIR/$project_input"
fi

# 2) slugified folder match
if [[ -z "$project_dir" ]]; then
  slug="$(slugify "$project_input")"
  if [[ -d "$PROJECTS_DIR/$slug" ]]; then
    resolved_project="$slug"
    project_dir="$PROJECTS_DIR/$slug"
  fi
fi

# 3) deterministic case-insensitive fallback
if [[ -z "$project_dir" ]]; then
  match_slug="$(slugify "$project_input")"
  while IFS= read -r d; do
    base="$(basename "$d")"
    if [[ "$(slugify "$base")" == "$match_slug" ]]; then
      resolved_project="$base"
      project_dir="$d"
      break
    fi
  done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi

if [[ -z "$project_dir" ]]; then
  echo "**Project:** $project_input"
  echo
  echo "Project directory not found under \`memory/projects/\`."
  echo
  echo "Create these files:"
  echo "- \`memory/projects/$(slugify "$project_input")/overview.md\`"
  echo "- \`memory/projects/$(slugify "$project_input")/log.md\`"
  exit 0
fi

overview_file="$project_dir/overview.md"
log_file="$project_dir/log.md"
rel_overview="projects/${resolved_project}/overview.md"
rel_log="projects/${resolved_project}/log.md"

goal_tmp="$(mktemp)"
constraints_tmp="$(mktemp)"
next_tmp="$(mktemp)"
blockers_tmp="$(mktemp)"
updates_tmp="$(mktemp)"
entries_all_tmp="$(mktemp)"
entries_since_tmp="$(mktemp)"
selected_entries_tmp="$(mktemp)"
evidence_tmp="$(mktemp)"
safe_log_tmp=""
trap 'rm -f "$goal_tmp" "$constraints_tmp" "$next_tmp" "$blockers_tmp" "$next_tmp".* "$blockers_tmp".* "$updates_tmp" "$entries_all_tmp" "$entries_since_tmp" "$selected_entries_tmp" "$evidence_tmp" "$safe_log_tmp"' EXIT

goal_text=""
constraints_text=""
current_status=""
missing_files=()
next_snapshot_found=0
blockers_snapshot_found=0

# Overview parsing
if [[ -f "$overview_file" ]]; then
  goal_block="$(extract_heading_block "$overview_file" '^#{1,6}[[:space:]]*(goal|goals|current approach|overview)[[:space:]]*$' || true)"
  constraints_block="$(extract_heading_block "$overview_file" '^#{1,6}[[:space:]]*(constraints?|scope|non-goals?)[[:space:]]*$' || true)"

  if [[ -n "$goal_block" ]]; then
    collect_list_items "$goal_block" "$goal_tmp"
    if [[ ! -s "$goal_tmp" ]]; then
      printf '%s\n' "$goal_block" | sed -n '1,3p' | redact_inline > "$goal_tmp"
    fi
  else
    extract_first_lines_fallback "$overview_file" | sed -n '1,3p' | redact_inline > "$goal_tmp"
  fi

  if [[ -n "$constraints_block" ]]; then
    collect_list_items "$constraints_block" "$constraints_tmp"
    if [[ ! -s "$constraints_tmp" ]]; then
      printf '%s\n' "$constraints_block" | sed -n '1,5p' | redact_inline > "$constraints_tmp"
    fi
  fi

  goal_text="$(sed -n '1,3p' "$goal_tmp" | paste -sd '; ' -)"
  [[ -n "$goal_text" ]] || goal_text="(Not clearly specified in overview.md)"

  constraints_text="$(sed -n '1,5p' "$constraints_tmp")"
  [[ -n "$constraints_text" ]] || constraints_text="(No explicit constraints found in overview.md)"

  ov_total="$(wc -l < "$overview_file" | tr -d ' ')"
  ov_end=20
  if [[ "$ov_total" -lt 20 ]]; then ov_end="$ov_total"; fi
  printf '%s (lines 1-%s)\n' "$rel_overview" "$ov_end" >> "$evidence_tmp"
else
  missing_files+=("$rel_overview")
  goal_text="(Missing overview.md)"
  constraints_text="(Missing overview.md)"
fi

# Log parsing
if [[ -f "$log_file" ]]; then
  safe_log_tmp="$(mktemp)"
  secret_scan_filter_file_read "$log_file" > "$safe_log_tmp"
  log_file="$safe_log_tmp"
  total_lines="$(wc -l < "$log_file" | tr -d ' ')"
  header_lines=()
  while IFS= read -r ln || [[ -n "$ln" ]]; do
    [[ -n "$ln" ]] || continue
    header_lines+=("$ln")
  done < <(grep -nE '^##[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]][0-9]{2}:[0-9]{2})?.*$' "$log_file" | cut -d: -f1 || true)

  if [[ "${#header_lines[@]}" -gt 0 ]]; then
    for ((i=${#header_lines[@]}-1; i>=0; i--)); do
      start="${header_lines[$i]}"
      if (( i < ${#header_lines[@]}-1 )); then
        end=$(( header_lines[$((i+1))] - 1 ))
      else
        end="$total_lines"
      fi

      header_raw="$(sed -n "${start}p" "$log_file" | sed -E 's/^##[[:space:]]*//')"
      entry_date="$(printf '%s\n' "$header_raw" | sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p')"
      [[ -n "$entry_date" ]] || continue
      entry_epoch="$(date_to_epoch "$entry_date")"

      entry_status="$(sed -n "${start},${end}p" "$log_file" | sed -nE 's/^Status:[[:space:]]*(.*)$/\1/p' | head -n1 | redact_inline)"

      # Summary one-liner: status first, else first bullet/text line.
      summary=""
      if [[ -n "$entry_status" ]]; then
        summary="$entry_status"
      else
        summary="$(sed -n "${start},${end}p" "$log_file" \
          | awk '
              NR==1{next}
              /^[[:space:]]*$/ {next}
              /^[A-Za-z][A-Za-z \/ -]*:[[:space:]]*$/ {next}
              /^## / {next}
              {
                s=$0
                sub(/^[[:space:]]*-[[:space:]]*/, "", s)
                sub(/^[[:space:]]*\[[ xX]\][[:space:]]*/, "", s)
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                if (s!="") { print s; exit }
              }' \
          | head -n1 | redact_inline)"
      fi
      [[ -n "$summary" ]] || summary="(No summary text)"

      # Next actions
      next_block="$(sed -n "${start},${end}p" "$log_file" | awk '
        BEGIN { in_next=0 }
        /^Next:[[:space:]]*$/ { in_next=1; next }
        /^Next:[[:space:]]+/ { s=$0; sub(/^Next:[[:space:]]*/, "", s); print s; in_next=1; next }
        /^[A-Za-z][A-Za-z \/ -]*:/ && in_next { in_next=0; next }
        in_next { print }
      ')"

      # Blockers / Risks
      blockers_block="$(sed -n "${start},${end}p" "$log_file" | awk '
        BEGIN { in_blk=0 }
        /^Blockers([[:space:]]*\/[[:space:]]*Risks)?:[[:space:]]*$/ { in_blk=1; next }
        /^Blockers([[:space:]]*\/[[:space:]]*Risks)?:[[:space:]]+/ { s=$0; sub(/^Blockers([[:space:]]*\/[[:space:]]*Risks)?:[[:space:]]*/, "", s); print s; in_blk=1; next }
        /^[A-Za-z][A-Za-z \/ -]*:/ && in_blk { in_blk=0; next }
        in_blk { print }
      ')"

      # Persist parsed entries as tab row.
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$entry_date" "$entry_epoch" "$start" "$end" \
        "${entry_status:-__NONE__}" \
        "$summary" \
        "$header_raw" >> "$entries_all_tmp"

      if [[ -n "$since_epoch" && "$entry_epoch" -ge "$since_epoch" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$entry_date" "$entry_epoch" "$start" "$end" \
          "${entry_status:-__NONE__}" \
          "$summary" \
          "$header_raw" >> "$entries_since_tmp"
      fi

      # Preserve explicit empty/None fields as snapshots that clear older data.
      if sed -n "${start},${end}p" "$log_file" | grep -q '^Next:'; then
        : > "$next_tmp.$start.$end"
        collect_list_items "$next_block" "$next_tmp.$start.$end" 1 1
      fi
      if sed -n "${start},${end}p" "$log_file" | grep -Eq '^Blockers([[:space:]]*/[[:space:]]*Risks)?:'; then
        : > "$blockers_tmp.$start.$end"
        collect_list_items "$blockers_block" "$blockers_tmp.$start.$end" 1 1
      fi
    done
  fi

  # Choose entries: prefer --since subset when available.
  if [[ -s "$entries_since_tmp" ]]; then
    cp "$entries_since_tmp" "$selected_entries_tmp"
  elif [[ -s "$entries_all_tmp" ]]; then
    cp "$entries_all_tmp" "$selected_entries_tmp"
  fi

  if [[ -s "$selected_entries_tmp" ]]; then
    # Current fields use all entries; --since only selects the update history.
    current_status_raw="$(awk -F'\t' '$5!="__NONE__" && $5!="" {print $5; exit}' "$entries_all_tmp")"
    if [[ "$current_status_raw" == "__NONE__" || -z "$current_status_raw" ]]; then
      current_status="$(head -n1 "$entries_all_tmp" | awk -F'\t' '{print $6}' | redact_inline)"
    else
      current_status="$(printf '%s' "$current_status_raw" | redact_inline)"
    fi
    [[ -n "$current_status" ]] || current_status="(No status line found in latest entry)"

    # Each field independently uses its latest explicit snapshot. An omitted
    # field inherits; an empty or None field clears prior actions/blockers.
    next_snapshot_found=0
    blockers_snapshot_found=0
    while IFS=$'\t' read -r _d _e start end _s _sum _h || [[ -n "$start" ]]; do
      if [[ "$next_snapshot_found" -eq 0 && -f "$next_tmp.$start.$end" ]]; then
        cp "$next_tmp.$start.$end" "$next_tmp"
        next_snapshot_found=1
        printf '%s (lines %s-%s)\n' "$rel_log" "$start" "$end" >> "$evidence_tmp"
      fi
      if [[ "$blockers_snapshot_found" -eq 0 && -f "$blockers_tmp.$start.$end" ]]; then
        cp "$blockers_tmp.$start.$end" "$blockers_tmp"
        blockers_snapshot_found=1
        printf '%s (lines %s-%s)\n' "$rel_log" "$start" "$end" >> "$evidence_tmp"
      fi
      if [[ "$next_snapshot_found" -eq 1 && "$blockers_snapshot_found" -eq 1 ]]; then
        break
      fi
    done < "$entries_all_tmp"

    # Recent updates
    u=0
    while IFS=$'\t' read -r d _e start end _s sum header || [[ -n "$d" ]]; do
      u=$((u + 1))
      (( u <= max_updates )) || break
      sum="$(printf '%s' "$sum" | redact_inline)"
      printf '%s — %s\n' "$d" "$sum" >> "$updates_tmp"
      printf '%s (lines %s-%s)\n' "$rel_log" "$start" "$end" >> "$evidence_tmp"
    done < "$selected_entries_tmp"
  else
    current_status="(No parseable log entries found in log.md)"
  fi
else
  missing_files+=("$rel_log")
  current_status="(Missing log.md)"
fi

echo "**Project:** $resolved_project"
echo
echo "**Goal:** $goal_text"
echo
echo "**Constraints:**"
if [[ "$constraints_text" == "(Missing overview.md)" || "$constraints_text" == "(No explicit constraints found in overview.md)" ]]; then
  echo "- $constraints_text"
else
  while IFS= read -r c || [[ -n "$c" ]]; do
    [[ -z "$c" ]] && continue
    echo "- $c"
  done <<< "$constraints_text"
fi
echo
echo "**Current Status:** $current_status"
echo
echo "**Next Actions:**"
if [[ -s "$next_tmp" ]]; then
  while IFS= read -r n || [[ -n "$n" ]]; do
    [[ -z "$n" ]] && continue
    echo "- $n"
  done < "$next_tmp"
else
  if [[ "$next_snapshot_found" -eq 1 ]]; then
    echo "- (None.)"
  else
    echo "- (No explicit next actions found in log entries.)"
  fi
fi
echo
echo "**Blockers / Risks:**"
if [[ -s "$blockers_tmp" ]]; then
  while IFS= read -r b || [[ -n "$b" ]]; do
    [[ -z "$b" ]] && continue
    echo "- $b"
  done < "$blockers_tmp"
else
  if [[ "$blockers_snapshot_found" -eq 1 ]]; then
    echo "- (None.)"
  else
    echo "- (No explicit blockers or risks found in log entries.)"
  fi
fi
echo
echo "**Recent Updates:**"
if [[ -s "$updates_tmp" ]]; then
  while IFS= read -r u || [[ -n "$u" ]]; do
    [[ -z "$u" ]] && continue
    echo "- $u"
  done < "$updates_tmp"
else
  echo "- (No recent updates available.)"
fi
echo
echo "**Evidence:**"
if [[ -s "$evidence_tmp" ]]; then
  awk '!seen[$0]++' "$evidence_tmp" | head -n 8 | while IFS= read -r ev || [[ -n "$ev" ]]; do
    [[ -z "$ev" ]] && continue
    echo "- $ev"
  done
else
  echo "- (No evidence files were parsed.)"
fi

if [[ "${#missing_files[@]}" -gt 0 ]]; then
  echo
  echo "Missing files:"
  for m in "${missing_files[@]}"; do
    echo "- $m"
  done
  echo
  echo "Create these files:"
  if printf '%s\n' "${missing_files[@]}" | grep -Fq -- "$rel_overview"; then
    echo "- \`$rel_overview\` with sections: Goal, Constraints, Current Approach, Key Decisions."
  fi
  if printf '%s\n' "${missing_files[@]}" | grep -Fq -- "$rel_log"; then
    echo "- \`$rel_log\` with entry blocks: Status, Notes, Next, Blockers."
  fi
fi

}

secret_scan_run_read_main secret_scan_reader_main "$@"
