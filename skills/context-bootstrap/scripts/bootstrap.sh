#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DECISION_SCRIPT="$REPO_ROOT/skills/decision-check/scripts/check.sh"
PROJECT_SCRIPT="$REPO_ROOT/skills/project-status/scripts/status.sh"
RETRIEVE_SCRIPT="$REPO_ROOT/skills/memory-retrieve/scripts/retrieve.sh"

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"
DEFAULT_SCOPES="decisions,projects,patterns,knowledge,logs"

usage() {
  cat <<'USAGE'
Usage:
  bootstrap.sh "<query>" [--project "<project>"] [--since YYYY-MM-DD] [--max-items N] [--max-updates N] [--min-confidence low|medium|high] [--scopes decisions,projects,...]
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

append_unique_line() {
  local file="$1"
  local line="$2"
  [[ -n "$line" ]] || return 0
  if [[ -f "$file" ]] && grep -Fxq -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$file"
}

normalize_text() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//'
}

add_dedup_normalized() {
  local out_file="$1"
  local seen_file="$2"
  local line="$3"
  local norm

  line="$(trim "$line")"
  [[ -n "$line" ]] || return 0

  norm="$(normalize_text "$line")"
  [[ -n "$norm" ]] || return 0

  if [[ -f "$seen_file" ]] && grep -Fxq -- "$norm" "$seen_file" 2>/dev/null; then
    return 0
  fi

  printf '%s\n' "$norm" >> "$seen_file"
  printf '%s\n' "$line" >> "$out_file"
}

record_failure() {
  local skill="$1"
  local code="$2"
  append_unique_line "$failure_notes_tmp" "skill=${skill} exit_code=${code} failed"
}

RUN_OUT=""
RUN_EXIT_CODE=0

run_source_skill() {
  local skill="$1"
  shift
  local script_path=""
  local out=""
  local rc=0

  if [[ $# -gt 0 ]]; then
    script_path="$1"
  fi

  if [[ -z "$script_path" || ! -x "$script_path" ]]; then
    RUN_OUT=""
    RUN_EXIT_CODE=127
    record_failure "$skill" 127
    return 0
  fi

  set +e
  out="$("$@" 2>/dev/null)"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    RUN_OUT=""
    RUN_EXIT_CODE="$rc"
    record_failure "$skill" "$rc"
    return 0
  fi

  RUN_OUT="$out"
  RUN_EXIT_CODE=0
}

query_tokens=()

build_query_tokens() {
  local query="$1"
  local normalized token
  local seen_tmp

  query_tokens=()
  seen_tmp="$(mktemp)"

  normalized="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g')"

  for token in $normalized; do
    [[ "${#token}" -ge 3 ]] || continue
    if grep -Fxq -- "$token" "$seen_tmp" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$token" >> "$seen_tmp"
    query_tokens+=("$token")
  done

  rm -f "$seen_tmp"
}

infer_project() {
  local query="$1"
  local projects_dir="$DEFAULT_MEMORY_ROOT/projects"
  local project_name project_norm matched
  local -a matches=()

  [[ -d "$projects_dir" ]] || return 0

  build_query_tokens "$query"
  if [[ "${#query_tokens[@]}" -eq 0 ]]; then
    return 0
  fi

  while IFS= read -r d || [[ -n "$d" ]]; do
    [[ -n "$d" ]] || continue
    project_name="$(basename "$d")"
    project_norm=" $(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g') "

    matched=0
    for token in "${query_tokens[@]}"; do
      if [[ "$project_norm" == *" $token "* ]]; then
        matched=1
        break
      fi
    done

    if [[ "$matched" -eq 1 ]]; then
      matches+=("$project_name")
    fi
  done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d | sort)

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

extract_constraints() {
  local input="$1"
  local out_file="$2"
  local seen_file="$3"
  local line marker

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == CONSTRAINT:* ]] || continue
    marker="${line#CONSTRAINT:}"
    marker="$(trim "$marker")"
    add_dedup_normalized "$out_file" "$seen_file" "$marker"
  done <<< "$input"

  if [[ -s "$out_file" ]]; then
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ "$line" =~ ^-[[:space:]]+ ]] || continue
    line="${line#- }"
    add_dedup_normalized "$out_file" "$seen_file" "$line"
  done < <(printf '%s\n' "$input" | awk '
    /^Constraints to obey:/ { in_sec=1; next }
    in_sec {
      if ($0 ~ /^$/) exit
      print
    }
  ')
}

extract_status_line() {
  local input="$1"
  local status
  status="$(printf '%s\n' "$input" | sed -nE 's/^\*\*Current Status:\*\*[[:space:]]*(.*)$/\1/p' | head -n1)"
  status="$(trim "$status")"
  [[ -n "$status" ]] && printf '%s\n' "$status"
}

extract_next_actions() {
  local input="$1"
  printf '%s\n' "$input" | awk '
    /^\*\*Next Actions:\*\*/ { in_sec=1; next }
    in_sec && /^\*\*[^*]+:\*\*/ { exit }
    in_sec {
      line=$0
      gsub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  '
}

normalize_memory_path() {
  local candidate="$1"
  local p

  p="$(trim "$candidate")"
  p="${p#\`}"
  p="${p%\`}"
  p="$(trim "$p")"

  [[ -n "$p" ]] || return 0
  if [[ "$p" == memory/* ]]; then
    p="${p#memory/}"
  fi

  case "$p" in
    decisions/*|projects/*|patterns/*|knowledge/*|logs/*)
      printf '%s\n' "$p"
      ;;
    *)
      return 0
      ;;
  esac
}

extract_evidence_paths() {
  local input="$1"
  local out_file="$2"
  local line match path

  while IFS= read -r line || [[ -n "$line" ]]; do
    while IFS= read -r match || [[ -n "$match" ]]; do
      [[ -n "$match" ]] || continue
      path="$(normalize_memory_path "$match" || true)"
      [[ -n "$path" ]] || continue
      append_unique_line "$out_file" "$path"
    done < <(printf '%s\n' "$line" | grep -Eo '(memory/)?(decisions|projects|patterns|knowledge|logs)/[A-Za-z0-9._/-]+' || true)
  done <<< "$input"
}

extract_pattern_paths() {
  local evidence_file="$1"
  local out_file="$2"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == patterns/* ]]; then
      append_unique_line "$out_file" "$line"
    fi
  done < "$evidence_file"
}

query=""
project=""
since=""
max_items=7
max_updates=5
min_confidence="medium"
scopes="$DEFAULT_SCOPES"
scopes_explicit=0

should_include_logs() {
  local q="$1"
  local qn
  qn="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')"

  if [[ "$qn" == *"what happened recently"* || "$qn" == *"happened recently"* || "$qn" == *"recently"* || "$qn" == *"recent"* || "$qn" == *"timeline"* || "$qn" == *"history"* || "$qn" == *"yesterday"* || "$qn" == *"today"* ]]; then
    return 0
  fi

  if printf '%s\n' "$qn" | grep -Eq '(^|[^a-z0-9])(log|logs)([^a-z0-9]|$)'; then
    return 0
  fi

  return 1
}

is_runbook_intent() {
  local q="$1"
  local qn
  qn="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$qn" | grep -Eq '(^|[^a-z0-9])(how|steps|runbook|procedure|playbook|debug|triage|deploy)([^a-z0-9]|$)'
}

needs_project_context() {
  local q="$1"
  local qn
  qn="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')"
  [[ "$qn" == *"where were we"* ]] && return 0
  printf '%s\n' "$qn" | grep -Eq '(^|[^a-z0-9])(status|next|continue|blocker|roadmap)([^a-z0-9]|$)'
}

derive_retrieve_scopes() {
  local q="$1"
  local project_hint="$2"
  local out=""

  add_scope() {
    local scope_name="$1"
    if [[ ",$out," != *",$scope_name,"* ]]; then
      if [[ -z "$out" ]]; then
        out="$scope_name"
      else
        out="$out,$scope_name"
      fi
    fi
  }

  if is_runbook_intent "$q"; then
    add_scope "patterns"
    add_scope "decisions"
    add_scope "knowledge"
    if [[ -n "$project_hint" ]] || needs_project_context "$q"; then
      add_scope "projects"
    fi
  else
    # Architecture/default: constraints + project state + procedures + references.
    add_scope "decisions"
    add_scope "projects"
    add_scope "patterns"
    add_scope "knowledge"
  fi

  if should_include_logs "$q"; then
    add_scope "logs"
  fi

  [[ -n "$out" ]] || out="decisions,projects,patterns,knowledge"
  printf '%s\n' "$out"
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

query="$(trim "$1")"
shift
[[ -n "$query" ]] || die "query must be non-empty"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "missing value for --project"
      project="$(trim "$2")"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || die "missing value for --since"
      since="$(trim "$2")"
      shift 2
      ;;
    --max-items)
      [[ $# -ge 2 ]] || die "missing value for --max-items"
      max_items="$2"
      shift 2
      ;;
    --max-updates)
      [[ $# -ge 2 ]] || die "missing value for --max-updates"
      max_updates="$2"
      shift 2
      ;;
    --min-confidence)
      [[ $# -ge 2 ]] || die "missing value for --min-confidence"
      min_confidence="$(trim "$2")"
      shift 2
      ;;
    --scopes)
      [[ $# -ge 2 ]] || die "missing value for --scopes"
      scopes="$(trim "$2")"
      scopes_explicit=1
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

[[ "$max_items" =~ ^[0-9]+$ ]] || die "--max-items must be an integer"
(( max_items >= 1 )) || die "--max-items must be >= 1"
(( max_items <= 12 )) || max_items=12

[[ "$max_updates" =~ ^[0-9]+$ ]] || die "--max-updates must be an integer"
(( max_updates >= 1 )) || die "--max-updates must be >= 1"
(( max_updates <= 10 )) || max_updates=10

case "$min_confidence" in
  low|medium|high) ;;
  *) die "--min-confidence must be low|medium|high" ;;
esac

if [[ -n "$since" ]]; then
  valid_date "$since" || die "--since must be valid YYYY-MM-DD"
fi

if [[ -z "$project" ]]; then
  project="$(infer_project "$query" || true)"
fi

retrieve_scopes="$scopes"
if [[ "$scopes_explicit" -eq 0 ]]; then
  retrieve_scopes="$(derive_retrieve_scopes "$query" "$project")"
fi

constraints_tmp="$(mktemp)"
constraints_seen_tmp="$(mktemp)"
next_actions_tmp="$(mktemp)"
evidence_tmp="$(mktemp)"
patterns_tmp="$(mktemp)"
failure_notes_tmp="$(mktemp)"
trap 'rm -f "$constraints_tmp" "$constraints_seen_tmp" "$next_actions_tmp" "$evidence_tmp" "$patterns_tmp" "$failure_notes_tmp"' EXIT

decision_cmd=("$DECISION_SCRIPT" "$query" "--max-items" "$max_items" "--min-confidence" "$min_confidence")
if [[ -n "$since" ]]; then
  decision_cmd+=("--since" "$since")
fi
run_source_skill "decision-check" "${decision_cmd[@]}"
decision_out="$RUN_OUT"

project_out=""
if [[ -n "$project" ]]; then
  project_cmd=("$PROJECT_SCRIPT" "$project" "--max-updates" "$max_updates")
  if [[ -n "$since" ]]; then
    project_cmd+=("--since" "$since")
  fi
  run_source_skill "project-status" "${project_cmd[@]}"
  project_out="$RUN_OUT"
fi

retrieve_cmd=("$RETRIEVE_SCRIPT" "$query" "--scopes" "$retrieve_scopes" "--max-items" "$max_items")
if [[ -n "$since" ]]; then
  retrieve_cmd+=("--since" "$since")
fi
if [[ -n "$project" ]]; then
  retrieve_cmd+=("--project" "$project")
fi
run_source_skill "memory-retrieve" "${retrieve_cmd[@]}"
retrieve_out="$RUN_OUT"

extract_constraints "$decision_out" "$constraints_tmp" "$constraints_seen_tmp"
extract_evidence_paths "$decision_out" "$evidence_tmp"
extract_evidence_paths "$project_out" "$evidence_tmp"
extract_evidence_paths "$retrieve_out" "$evidence_tmp"
extract_pattern_paths "$evidence_tmp" "$patterns_tmp"

current_status=""
if [[ -n "$project_out" ]]; then
  current_status="$(extract_status_line "$project_out" || true)"
  while IFS= read -r action || [[ -n "$action" ]]; do
    action="$(trim "$action")"
    [[ -n "$action" ]] || continue
    append_unique_line "$next_actions_tmp" "$action"
  done < <(extract_next_actions "$project_out")
fi

echo "## Context"
echo
echo "### Applicable constraints"
if [[ -s "$constraints_tmp" ]]; then
  while IFS= read -r c || [[ -n "$c" ]]; do
    [[ -n "$c" ]] || continue
    echo "- $c"
  done < "$constraints_tmp"
else
  echo "- No relevant decision found."
fi

echo
echo "### Current project status"
if [[ -n "$project" && -n "$project_out" ]]; then
  echo "- Project: $project"
  if [[ -n "$current_status" ]]; then
    echo "- Current status: $current_status"
  else
    echo "- Current status: (none)"
  fi
  if [[ -s "$next_actions_tmp" ]]; then
    next_joined="$(paste -sd '; ' "$next_actions_tmp")"
    echo "- Next actions: $next_joined"
  else
    echo "- Next actions: (none)"
  fi
elif [[ -n "$project" ]]; then
  echo "- Project: $project"
  echo "- Current status: (skipped)"
else
  echo "- Project: (skipped: no unique inferred project)"
fi

echo
echo "### Relevant patterns"
if [[ -s "$patterns_tmp" ]]; then
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -n "$p" ]] || continue
    echo "- $p"
  done < "$patterns_tmp"
else
  echo "- (none)"
fi

echo
echo "### Evidence"
if [[ -s "$evidence_tmp" ]]; then
  while IFS= read -r ev || [[ -n "$ev" ]]; do
    [[ -n "$ev" ]] || continue
    echo "- $ev"
  done < "$evidence_tmp"
fi
if [[ -s "$failure_notes_tmp" ]]; then
  while IFS= read -r note || [[ -n "$note" ]]; do
    [[ -n "$note" ]] || continue
    echo "- $note"
  done < "$failure_notes_tmp"
fi
if [[ ! -s "$evidence_tmp" && ! -s "$failure_notes_tmp" ]]; then
  echo "- (none)"
fi
