#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"

usage() {
  cat <<'EOF'
Usage:
  check.sh "<query>" [--max-items N] [--min-confidence low|medium|high] [--since YYYY-MM-DD]

Options:
  --max-items       Maximum decision entries to return (default 5, hard cap 8)
  --min-confidence  low|medium|high (default medium)
  --since           YYYY-MM-DD; used as tie-break preference for newer decisions
  -h, --help        Show this help
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
  printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
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
    return 0
  fi
  date -d "$d" "+%s"
}

file_epoch() {
  local f="$1"
  local d e
  d="$(grep -m1 -E '^Date:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$' "$f" 2>/dev/null | sed -E 's/^Date:[[:space:]]*//' || true)"
  if [[ -n "$d" ]] && valid_date "$d"; then
    date_to_epoch "$d"
    return 0
  fi
  d="$(basename "$f" | grep -Eo '[0-9]{4}-[0-9]{2}' | head -n1 || true)"
  if [[ -n "$d" ]]; then
    e="$(date_to_epoch "${d}-01" || true)"
    if [[ -n "$e" ]]; then
      echo "$e"
      return 0
    fi
  fi
  if stat -f "%m" "$f" >/dev/null 2>&1; then
    stat -f "%m" "$f"
  else
    stat -c "%Y" "$f"
  fi
}

status_weight() {
  case "$1" in
    accepted) echo 3 ;;
    proposed) echo 2 ;;
    deprecated) echo 1 ;;
    *) echo 2 ;;
  esac
}

confidence_rank() {
  case "$1" in
    high) echo 3 ;;
    medium) echo 2 ;;
    low) echo 1 ;;
    *) echo 0 ;;
  esac
}

redact_inline() {
  sed -E \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/(AKIA[0-9A-Z]{16})/[REDACTED]/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9]{20,})/[REDACTED]/g' \
    -e 's/(sk-[A-Za-z0-9]{20,})/[REDACTED]/g' \
    -e 's/\beyJ[A-Za-z0-9._-]{10,}\b/[REDACTED]/g' \
    -e 's/\b[A-Fa-f0-9]{32,}\b/[REDACTED]/g' \
    -e 's/([Pp]assword|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][-_ ]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g'
}

count_text_hits() {
  local text="$1"
  local hits=0 k lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"$query_lower"* ]]; then
    hits=$((hits + 2))
  fi
  for k in "${keywords[@]:-}"; do
    [[ -z "$k" ]] && continue
    if [[ "$lower" == *"$k"* ]]; then
      hits=$((hits + 1))
    fi
  done
  echo "$hits"
}

line_matches_query() {
  local line="$1"
  if [[ -n "$keyword_re" ]]; then
    printf '%s\n' "$line" | grep -Eiq -- "$keyword_re"
  else
    printf '%s\n' "$line" | grep -Fqi -- "$query"
  fi
}

extract_section() {
  local file="$1"
  local section="$2"
  awk -v sec="## ${section}" '
    BEGIN { in_sec=0 }
    /^## / {
      if (in_sec && $0 != sec) exit
      in_sec = ($0 == sec)
      next
    }
    in_sec { print }
  ' "$file"
}

count_section_hits() {
  local file="$1"
  local section="$2"
  local text
  text="$(extract_section "$file" "$section" || true)"
  [[ -n "$text" ]] || { echo 0; return; }
  if [[ -n "$keyword_re" ]]; then
    printf '%s\n' "$text" | grep -Eic -- "$keyword_re" || true
  else
    printf '%s\n' "$text" | grep -Fic -- "$query" || true
  fi
}

count_body_hits() {
  local file="$1"
  local out
  if [[ -n "$keyword_re" ]]; then
    if command -v rg >/dev/null 2>&1; then
      out="$(rg -i -c -e "$keyword_re" -- "$file" 2>/dev/null || true)"
      printf '%s\n' "$out" | awk -F: '{s+=$NF} END{print s+0}'
    else
      grep -Eic -- "$keyword_re" "$file" 2>/dev/null || true
    fi
  else
    if command -v rg >/dev/null 2>&1; then
      out="$(rg -i -F -c -- "$query" "$file" 2>/dev/null || true)"
      printf '%s\n' "$out" | awk -F: '{s+=$NF} END{print s+0}'
    else
      grep -Fic -- "$query" "$file" 2>/dev/null || true
    fi
  fi
}

extract_constraints() {
  local file="$1"
  local tmp candidates line section clean score order op_re
  tmp="$(mktemp)"
  candidates="$(mktemp)"

  awk '
    function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function clean(s){
      s=trim(s)
      sub(/^-[[:space:]]*/, "", s)
      sub(/^\[[ xX]\][[:space:]]*/, "", s)
      return s
    }
    /^## /{
      sec=""
      if ($0=="## Decision") sec="Decision"
      else if ($0=="## Consequences") sec="Consequences"
      else if ($0=="## Tradeoffs") sec="Tradeoffs"
      next
    }
    sec!=""{
      line=clean($0)
      if (line!="") print sec "\t" line
    }
  ' "$file" > "$tmp"

  op_re='must|should|avoid|require|only|never|cannot|can not|do not|idempotent|immutable'
  order=0
  while IFS=$'\t' read -r section line || [[ -n "$section$line" ]]; do
    [[ -z "$line" ]] && continue
    order=$((order + 1))
    line="$(printf '%s' "$line" | sed -E 's/[[:space:]]+/ /g' | redact_inline)"

    score=0
    case "$section" in
      Decision) score=30 ;;
      Consequences) score=22 ;;
      Tradeoffs) score=12 ;;
      *) score=5 ;;
    esac

    if line_matches_query "$line"; then
      score=$((score + 12))
    fi
    if printf '%s\n' "$line" | grep -Eiq -- "$op_re"; then
      score=$((score + 6))
    fi

    if [[ "$section" == "Tradeoffs" ]] && [[ "$score" -lt 20 ]]; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$score" "$order" "$line" >> "$candidates"
  done < "$tmp"

  if [[ ! -s "$candidates" ]]; then
    rm -f "$tmp" "$candidates"
    return 0
  fi

  sort -t $'\t' -k1,1nr -k2,2n "$candidates" \
    | awk -F'\t' '!seen[$3]++ { print $3 }' \
    | head -n 5

  rm -f "$tmp" "$candidates"
}

query=""
max_items=5
min_confidence="medium"
since=""

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

query="$1"
shift
query="$(trim "$query")"
[[ -n "$query" ]] || die "query must be non-empty"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-items)
      [[ $# -ge 2 ]] || die "missing value for --max-items"
      max_items="$2"
      shift 2
      ;;
    --min-confidence)
      [[ $# -ge 2 ]] || die "missing value for --min-confidence"
      min_confidence="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || die "missing value for --since"
      since="$2"
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$max_items" =~ ^[0-9]+$ ]] || die "--max-items must be an integer"
(( max_items >= 1 )) || die "--max-items must be >= 1"
(( max_items <= 8 )) || max_items=8

case "$min_confidence" in
  low|medium|high) ;;
  *) die "--min-confidence must be one of: low, medium, high" ;;
esac
min_conf_rank="$(confidence_rank "$min_confidence")"

since_epoch=""
if [[ -n "$since" ]]; then
  valid_date "$since" || die "--since must be valid YYYY-MM-DD"
  since_epoch="$(date_to_epoch "$since")"
fi

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
DECISIONS_DIR="$MEMORY_ROOT/decisions"
[[ -d "$DECISIONS_DIR" ]] || die "decisions directory not found: $DECISIONS_DIR"

query_lower="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"
normalized_query="$(printf '%s' "$query_lower" | sed -E 's/[^a-z0-9._ -]+/ /g')"
keywords=()
for w in $normalized_query; do
  if [[ "${#w}" -ge 3 ]]; then
    keywords+=("$w")
  fi
done
keyword_re=""
for k in "${keywords[@]:-}"; do
  ek="$(escape_regex "$k")"
  if [[ -z "$keyword_re" ]]; then
    keyword_re="$ek"
  else
    keyword_re="${keyword_re}|${ek}"
  fi
done

matches_file="$(mktemp)"
candidates_file="$(mktemp)"
sorted_file="$(mktemp)"
selected_file="$(mktemp)"
all_constraints_file="$(mktemp)"
trap 'rm -f "$matches_file" "$candidates_file" "$sorted_file" "$selected_file" "$all_constraints_file"' EXIT

# File-name prefilter.
while IFS= read -r -d '' f; do
  b="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
  if [[ "$b" == *"$query_lower"* ]]; then
    printf '%s\n' "$f" >> "$matches_file"
    continue
  fi
  for k in "${keywords[@]:-}"; do
    [[ -z "$k" ]] && continue
    if [[ "$b" == *"$k"* ]]; then
      printf '%s\n' "$f" >> "$matches_file"
      break
    fi
  done
done < <(find "$DECISIONS_DIR" -type f -name '*.md' -print0 2>/dev/null)

# Content prefilter via rg/grep.
if [[ -n "$keyword_re" ]]; then
  if command -v rg >/dev/null 2>&1; then
    rg -i -l -e "$keyword_re" "$DECISIONS_DIR" 2>/dev/null || true
  else
    grep -RilE -- "$keyword_re" "$DECISIONS_DIR" 2>/dev/null || true
  fi
else
  if command -v rg >/dev/null 2>&1; then
    rg -i -F -l -- "$query" "$DECISIONS_DIR" 2>/dev/null || true
  else
    grep -RilF -- "$query" "$DECISIONS_DIR" 2>/dev/null || true
  fi
fi >> "$matches_file"

if [[ ! -s "$matches_file" ]]; then
  echo "No relevant decision found."
  echo
  echo "- Consider recording: chosen approach and constraint boundaries."
  echo "- Consider recording: key tradeoffs and what was explicitly rejected."
  echo "- Consider recording: follow-up tasks required to enforce the decision."
  exit 0
fi

sort -u "$matches_file" > "$sorted_file"

while IFS= read -r file || [[ -n "$file" ]]; do
  [[ -f "$file" ]] || continue

  rel_path="${file#"$MEMORY_ROOT"/}"
  title="$(grep -m1 -E '^#[[:space:]]+' "$file" | sed -E 's/^#[[:space:]]*//' || true)"
  [[ -n "$title" ]] || title="$(basename "$file" .md)"
  date_str="$(grep -m1 -E '^Date:[[:space:]]*' "$file" | sed -E 's/^Date:[[:space:]]*//' || true)"
  if ! valid_date "$date_str"; then
    date_str="$(date -r "$(file_epoch "$file")" "+%Y-%m-%d" 2>/dev/null || echo "1970-01-01")"
  fi
  status="$(grep -m1 -E '^Status:[[:space:]]*' "$file" | sed -E 's/^Status:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' || true)"
  [[ -n "$status" ]] || status="accepted"
  supersedes="$(grep -m1 -E '^Supersedes:[[:space:]]*' "$file" | sed -E 's/^Supersedes:[[:space:]]*//' || true)"
  supersedes_safe="$supersedes"
  [[ -n "$supersedes_safe" ]] || supersedes_safe="__NONE__"
  date_epoch="$(file_epoch "$file")"

  filename_hits="$(count_text_hits "$(basename "$file")")"
  title_hits="$(count_text_hits "$title")"
  decision_hits="$(count_section_hits "$file" "Decision")"
  context_hits="$(count_section_hits "$file" "Context")"
  why_hits="$(count_section_hits "$file" "Why")"
  body_hits="$(count_body_hits "$file")"

  # Highest weight to filename/title, then core sections, then body.
  score=$(( (filename_hits + title_hits) * 30 + decision_hits * 20 + (context_hits + why_hits) * 10 + body_hits * 2 ))
  if [[ "$score" -le 0 ]]; then
    continue
  fi

  conf="low"
  conf_rank=1
  if (( (filename_hits + title_hits) >= 1 && decision_hits >= 1 )) || (( (filename_hits + title_hits) >= 2 && (context_hits + why_hits) >= 1 )); then
    conf="high"
    conf_rank=3
  elif (( (filename_hits + title_hits) >= 1 )) || (( decision_hits >= 1 )); then
    conf="medium"
    conf_rank=2
  else
    conf="low"
    conf_rank=1
  fi

  if (( conf_rank < min_conf_rank )); then
    continue
  fi

  since_match=0
  if [[ -n "$since_epoch" && "$date_epoch" -ge "$since_epoch" ]]; then
    since_match=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(status_weight "$status")" \
    "$date_epoch" \
    "$score" \
    "$since_match" \
    "$rel_path" \
    "$title" \
    "$date_str" \
    "$status" \
    "$supersedes_safe" \
    "$file" >> "$candidates_file"
done < "$sorted_file"

if [[ ! -s "$candidates_file" ]]; then
  echo "No relevant decision found."
  echo
  echo "- Consider recording: the chosen approach and the main constraints."
  echo "- Consider recording: tradeoffs and operational guardrails."
  echo "- Consider recording: explicit follow-ups to enforce the decision."
  exit 0
fi

# Ranking priority: status > newer date > query-hit score; since is tie preference.
sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5 "$candidates_file" > "$sorted_file"
head -n "$max_items" "$sorted_file" > "$selected_file"

echo "Existing decision(s) apply:"
echo

idx=0
while IFS=$'\t' read -r _sw _de _sc _sm rel_path title date_str status supersedes file || [[ -n "$rel_path" ]]; do
  if [[ "$supersedes" == "__NONE__" ]]; then
    supersedes=""
  fi
  idx=$((idx + 1))
  echo "${idx}) \`${rel_path}\`"
  echo "- Title: ${title}"
  echo "- Date: ${date_str}"
  echo "- Status: ${status}"

  echo "- Constraints:"
  constraints_count=0
  while IFS= read -r c || [[ -n "$c" ]]; do
    [[ -z "$c" ]] && continue
    constraints_count=$((constraints_count + 1))
    echo "  - ${c}"
    printf '%s\n' "$c" >> "$all_constraints_file"
  done < <(extract_constraints "$file")
  if [[ "$constraints_count" -eq 0 ]]; then
    echo "  - (No explicit constraints extracted; review sections: Decision/Consequences/Tradeoffs.)"
  fi

  if [[ -n "$supersedes" ]]; then
    echo "- Supersedes: ${supersedes}"
  fi
  superseded_by="$(awk -F'\t' -v p="$rel_path" '$9==p {print $5}' "$selected_file" | paste -sd ', ' - || true)"
  if [[ -n "$superseded_by" ]]; then
    echo "- Superseded-by: ${superseded_by}"
  fi
  echo
done < "$selected_file"

echo "Constraints to obey:"
if [[ -s "$all_constraints_file" ]]; then
  awk '!seen[$0]++' "$all_constraints_file" | while IFS= read -r c || [[ -n "$c" ]]; do
    [[ -z "$c" ]] && continue
    echo "- ${c}"
  done
else
  echo "- (No extracted constraints; inspect matched decisions directly.)"
fi

statuses_distinct="$(awk -F'\t' '{print $8}' "$selected_file" | sort -u | tr '\n' ' ' | sed -E 's/[[:space:]]+$//' )"
status_count="$(awk -F'\t' '{print $8}' "$selected_file" | sort -u | wc -l | tr -d ' ')"
if [[ "$status_count" -gt 1 ]]; then
  echo
  echo "Conflict note:"
  echo "- Mixed decision statuses detected (${statuses_distinct}). Prefer newer accepted decisions."
fi
