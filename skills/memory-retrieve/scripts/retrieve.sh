#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"
DEFAULT_SCOPES="decisions,projects,patterns,knowledge,logs"

usage() {
  cat <<'EOF'
Usage:
  retrieve.sh "<query>" [--scopes decisions,projects,...] [--max-items N] [--since YYYY-MM-DD] [--project name]

Options:
  --scopes     Comma-separated scopes: decisions,projects,patterns,knowledge,logs
  --max-items  Max evidence items to return (default 7, hard cap 12)
  --since      Date filter for logs/projects (YYYY-MM-DD)
  --project    Project hint to bias toward projects/<name>/
  -h, --help   Show this help message
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

escape_regex() {
  printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\]/\\&/g'
}

is_valid_scope() {
  case "$1" in
    decisions|projects|patterns|knowledge|logs) return 0 ;;
    *) return 1 ;;
  esac
}

scope_priority() {
  case "$1" in
    decisions) echo 1 ;;
    projects) echo 2 ;;
    patterns) echo 3 ;;
    knowledge) echo 4 ;;
    logs) echo 5 ;;
    *) echo 99 ;;
  esac
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

file_mtime_epoch() {
  local f="$1"
  if stat -f "%m" "$f" >/dev/null 2>&1; then
    stat -f "%m" "$f"
  else
    stat -c "%Y" "$f"
  fi
}

file_epoch() {
  local f="$1"
  local b d e
  b="$(basename "$f")"
  d="$(printf '%s\n' "$b" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1 || true)"
  if [[ -n "$d" ]]; then
    e="$(date_to_epoch "$d" || true)"
    if [[ -n "$e" ]]; then
      echo "$e"
      return 0
    fi
  fi
  file_mtime_epoch "$f"
}

count_fixed_ci() {
  local file="$1"
  local term="$2"
  local out
  [[ -z "$term" ]] && { echo 0; return; }
  if command -v rg >/dev/null 2>&1; then
    out="$(rg -i -F -c -- "$term" "$file" 2>/dev/null || true)"
    printf '%s\n' "$out" | awk -F: '{s+=$NF} END{print s+0}'
  else
    out="$(grep -iF -c -- "$term" "$file" 2>/dev/null || true)"
    [[ -n "$out" ]] && printf '%s\n' "$out" || echo 0
  fi
}

count_regex_ci() {
  local file="$1"
  local re="$2"
  local out
  [[ -z "$re" ]] && { echo 0; return; }
  if command -v rg >/dev/null 2>&1; then
    out="$(rg -i -e "$re" -c -- "$file" 2>/dev/null || true)"
    printf '%s\n' "$out" | awk -F: '{s+=$NF} END{print s+0}'
  else
    out="$(grep -iE -c -- "$re" "$file" 2>/dev/null || true)"
    [[ -n "$out" ]] && printf '%s\n' "$out" || echo 0
  fi
}

count_heading_fixed_ci() {
  local file="$1"
  local term="$2"
  [[ -z "$term" ]] && { echo 0; return; }
  awk -v q="$term" '
    BEGIN { c=0; q=tolower(q) }
    /^#{1,6}[[:space:]]/ {
      line=tolower($0)
      if (index(line, q) > 0) c++
    }
    END { print c+0 }
  ' "$file" 2>/dev/null || echo 0
}

count_heading_regex_ci() {
  local file="$1"
  local re="$2"
  local out
  [[ -z "$re" ]] && { echo 0; return; }
  out="$(grep -iE -c "^#{1,6}[[:space:]].*(${re})" "$file" 2>/dev/null || true)"
  [[ -n "$out" ]] && printf '%s\n' "$out" || echo 0
}

first_match_line() {
  local file="$1"
  local query="$2"
  local keyword_re="$3"
  local line=""

  if command -v rg >/dev/null 2>&1; then
    line="$(rg -n -i -F -m 1 -- "$query" "$file" 2>/dev/null | head -n 1 | sed -E 's/:.*$//' || true)"
    if [[ -z "$line" && -n "$keyword_re" ]]; then
      line="$(rg -n -i -e "$keyword_re" -m 1 -- "$file" 2>/dev/null | head -n 1 | sed -E 's/:.*$//' || true)"
    fi
  else
    line="$(grep -inF -- "$query" "$file" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
    if [[ -z "$line" && -n "$keyword_re" ]]; then
      line="$(grep -inE -- "$keyword_re" "$file" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
    fi
  fi

  [[ -n "$line" ]] && echo "$line" || echo 1
}

first_heading() {
  local file="$1"
  grep -m 1 -E '^#{1,6}[[:space:]]' "$file" 2>/dev/null | sed -E 's/^#{1,6}[[:space:]]*//' || true
}

redact_excerpt() {
  sed -E \
    -e 's/([Pp]assword|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][-_ ]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/\beyJ[A-Za-z0-9._-]{10,}\b/[REDACTED]/g' \
    -e 's/\b[A-Fa-f0-9]{32,}\b/[REDACTED]/g' \
    -e 's/(AKIA[0-9A-Z]{16})/[REDACTED]/g'
}

trim_excerpt() {
  local s="$1"
  local max_chars="${2:-200}"
  s="$(printf '%s' "$s" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
  if [[ "${#s}" -gt "$max_chars" ]]; then
    printf '%s…' "$(printf '%s' "$s" | cut -c1-"$((max_chars - 1))")"
  else
    printf '%s' "$s"
  fi
}

summary_reason() {
  local scope="$1"
  local heading_hit="$2"
  case "$scope" in
    decisions)
      [[ "$heading_hit" -eq 1 ]] && echo "Decision context matched in headings" || echo "Decision context matched query terms"
      ;;
    projects)
      [[ "$heading_hit" -eq 1 ]] && echo "Project status context matched in headings" || echo "Project status context matched query terms"
      ;;
    patterns)
      [[ "$heading_hit" -eq 1 ]] && echo "Reusable pattern matched in headings" || echo "Reusable pattern matched query terms"
      ;;
    knowledge)
      [[ "$heading_hit" -eq 1 ]] && echo "Reference note matched in headings" || echo "Reference note matched query terms"
      ;;
    logs)
      [[ "$heading_hit" -eq 1 ]] && echo "Recent log context matched in headings" || echo "Recent log context matched query terms"
      ;;
    *)
      echo "Relevant context matched query terms"
      ;;
  esac
}

evidence_reason() {
  local scope="$1"
  local heading_hit="$2"
  if [[ "$heading_hit" -eq 1 ]]; then
    echo "Query keywords matched a section heading in prioritized scope \`$scope\`."
  else
    echo "Query keywords matched body text in prioritized scope \`$scope\`."
  fi
}

query=""
scopes_csv="$DEFAULT_SCOPES"
max_items=7
since=""
project=""

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "$1" = "-h" || "$1" = "--help" ]]; then
  usage
  exit 0
fi

query="$1"
shift

if [[ -z "$(trim "$query")" ]]; then
  die "query must be non-empty"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scopes)
      [[ $# -ge 2 ]] || die "missing value for --scopes"
      scopes_csv="$2"
      shift 2
      ;;
    --max-items)
      [[ $# -ge 2 ]] || die "missing value for --max-items"
      max_items="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || die "missing value for --since"
      since="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "missing value for --project"
      project="$2"
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

if ! [[ "$max_items" =~ ^[0-9]+$ ]]; then
  die "--max-items must be an integer"
fi
if [[ "$max_items" -lt 1 ]]; then
  die "--max-items must be >= 1"
fi
if [[ "$max_items" -gt 12 ]]; then
  max_items=12
fi

since_epoch=""
if [[ -n "$since" ]]; then
  if ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    die "--since must use YYYY-MM-DD"
  fi
  since_epoch="$(date_to_epoch "$since" || true)"
  if [[ -z "$since_epoch" ]]; then
    die "--since is not a valid date: $since"
  fi
fi

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
if [[ ! -d "$MEMORY_ROOT" ]]; then
  echo "Error: memory root not found: $MEMORY_ROOT" >&2
  exit 3
fi

scopes_csv="$(printf '%s' "$scopes_csv" | tr -d '[:space:]')"
IFS=',' read -r -a scopes <<< "$scopes_csv"
if [[ "${#scopes[@]}" -eq 0 ]]; then
  die "at least one scope is required"
fi
# Deduplicate scopes while preserving user order for deterministic behavior.
unique_scopes=()
seen_scopes=","
for s in "${scopes[@]}"; do
  [[ -z "$s" ]] && continue
  is_valid_scope "$s" || die "invalid scope: $s"
  if [[ "$seen_scopes" != *",$s,"* ]]; then
    unique_scopes+=("$s")
    seen_scopes="${seen_scopes}${s},"
  fi
done
scopes=("${unique_scopes[@]}")
if [[ "${#scopes[@]}" -eq 0 ]]; then
  die "at least one valid scope is required"
fi
scopes_display="$(printf '%s\n' "${scopes[*]}" | tr ' ' ',')"

normalized_query="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._ -]+/ /g')"
keywords=()
for word in $normalized_query; do
  if [[ "${#word}" -ge 3 ]]; then
    keywords+=("$word")
  fi
done

keyword_re=""
for k in "${keywords[@]}"; do
  ek="$(escape_regex "$k")"
  if [[ -z "$keyword_re" ]]; then
    keyword_re="$ek"
  else
    keyword_re="$keyword_re|$ek"
  fi
done

candidates_file="$(mktemp)"
sorted_file="$(mktemp)"
selected_file="$(mktemp)"
trap 'rm -f "$candidates_file" "$sorted_file" "$selected_file"' EXIT

for scope in "${scopes[@]}"; do
  scope_dir="$MEMORY_ROOT/$scope"
  [[ -d "$scope_dir" ]] || continue

  while IFS= read -r -d '' file; do
    if [[ -n "$since_epoch" && ( "$scope" = "logs" || "$scope" = "projects" ) ]]; then
      fe="$(file_epoch "$file")"
      if [[ "$fe" -lt "$since_epoch" ]]; then
        continue
      fi
    fi

    full_hits="$(count_fixed_ci "$file" "$query")"
    kw_hits="$(count_regex_ci "$file" "$keyword_re")"
    heading_full_hits="$(count_heading_fixed_ci "$file" "$query")"
    heading_kw_hits="$(count_heading_regex_ci "$file" "$keyword_re")"

    score=$((heading_full_hits * 40 + heading_kw_hits * 20 + full_hits * 8 + kw_hits * 3))
    if [[ "$score" -le 0 ]]; then
      continue
    fi

    if [[ -n "$project" && "$scope" = "projects" && "$file" == *"/$project/"* ]]; then
      score=$((score + 25))
    fi

    recency="$(file_epoch "$file")"
    line="$(first_match_line "$file" "$query" "$keyword_re")"
    heading_hit=0
    if [[ "$heading_full_hits" -gt 0 || "$heading_kw_hits" -gt 0 ]]; then
      heading_hit=1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(scope_priority "$scope")" \
      "$score" \
      "$recency" \
      "$scope" \
      "$file" \
      "$line" \
      "$heading_hit" >> "$candidates_file"
  done < <(find "$scope_dir" -type f -print0 2>/dev/null)
done

if [[ -s "$candidates_file" ]]; then
  # Stable tie-break by scope/path/line to keep output deterministic across runs.
  sort -t $'\t' -k1,1n -k2,2nr -k3,3nr -k4,4 -k5,5 -k6,6n "$candidates_file" > "$sorted_file"
  head -n "$max_items" "$sorted_file" > "$selected_file"
fi

echo "## Retrieved Context"
if [[ ! -s "$selected_file" ]]; then
  echo "- No relevant entries found for query: \"$query\"."
  echo "- Searched scopes: $scopes_display."
  echo
  echo "## Evidence"
  echo "1) None"
  echo "   - No matching files in selected scopes."
  exit 0
fi

summary_count=0
while IFS=$'\t' read -r _priority _score _recency scope file _line heading_hit; do
  summary_count=$((summary_count + 1))
  if [[ "$summary_count" -gt 10 ]]; then
    break
  fi
  rel="${file#"$MEMORY_ROOT"/}"
  heading="$(first_heading "$file")"
  reason="$(summary_reason "$scope" "$heading_hit")"
  if [[ -n "$heading" ]]; then
    echo "- $reason: \`$rel\` ($heading)"
  else
    echo "- $reason: \`$rel\`"
  fi
done < "$selected_file"

echo
echo "## Evidence"

ev_count=0
while IFS=$'\t' read -r _priority _score _recency scope file line heading_hit; do
  ev_count=$((ev_count + 1))
  rel="${file#"$MEMORY_ROOT"/}"
  lc="$(wc -l < "$file" | tr -d ' ')"
  if [[ "$line" -lt 1 ]]; then
    line=1
  fi
  start="$line"
  if [[ "$start" -gt 1 ]]; then
    start=$((start - 1))
  fi
  end=$((line + 1))
  if [[ "$end" -gt "$lc" ]]; then
    end="$lc"
  fi

  excerpt="$(sed -n "${line}p" "$file" 2>/dev/null || true)"
  excerpt="$(printf '%s' "$excerpt" | redact_excerpt)"
  excerpt="$(trim_excerpt "$excerpt" 200)"
  why="$(evidence_reason "$scope" "$heading_hit")"

  echo "${ev_count}) ${rel} (lines ${start}-${end})"
  echo "   - ${why}"
  if [[ -n "$excerpt" ]]; then
    echo "   - excerpt: \"${excerpt}\""
  fi
done < "$selected_file"
