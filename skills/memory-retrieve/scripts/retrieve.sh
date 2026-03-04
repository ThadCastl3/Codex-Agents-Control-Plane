#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"
DEFAULT_SCOPES="decisions,projects,patterns,knowledge,logs"
DEFAULT_MAX_ITEMS=7
MAX_ITEMS_HARD_CAP=12
MIN_THRESHOLD_DEFAULT=120
MIN_THRESHOLD_LOGS=80

usage() {
  cat <<'USAGE'
Usage:
  retrieve.sh "<query>" [--scopes decisions,projects,...] [--max-items N] [--since YYYY-MM-DD] [--project name] [--explain|--debug]

Options:
  --scopes     Comma-separated scopes: decisions,projects,patterns,knowledge,logs
  --max-items  Max evidence items to return (default 7, hard cap 12)
  --since      Date filter for logs/projects (YYYY-MM-DD)
  --project    Project hint to bias toward projects/<name>/
  --explain    Print per-selected-file score breakdown
  --debug      Alias for --explain
  -h, --help   Show this help message
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 2
}

trace() {
  if [[ "${MEMORY_RETRIEVE_TRACE:-0}" != "1" ]]; then
    return 0
  fi
  printf '[memory-retrieve] %s\n' "$*" >&2
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

slugify() {
  local in out
  in="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  out="$(printf '%s' "$in" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$out" ]] || out="project"
  printf '%s' "$out"
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

scope_base_weight() {
  case "$1" in
    decisions) echo 120 ;;
    projects) echo 110 ;;
    patterns) echo 105 ;;
    knowledge) echo 70 ;;
    logs) echo 25 ;;
    *) echo 0 ;;
  esac
}

scope_cap() {
  case "$1" in
    logs|knowledge) echo 3 ;;
    *) echo 4 ;;
  esac
}

scope_threshold() {
  case "$1" in
    logs) echo "$MIN_THRESHOLD_LOGS" ;;
    *) echo "$MIN_THRESHOLD_DEFAULT" ;;
  esac
}

recency_max_points() {
  case "$1" in
    logs) echo 40 ;;
    projects) echo 30 ;;
    decisions) echo 20 ;;
    patterns) echo 15 ;;
    knowledge) echo 15 ;;
    *) echo 0 ;;
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
      [[ "$heading_hit" -eq 1 ]] && echo "Authoritative decision constraints matched headings" || echo "Authoritative decision constraints matched query terms"
      ;;
    projects)
      [[ "$heading_hit" -eq 1 ]] && echo "Current project intent/state matched headings" || echo "Current project intent/state matched query terms"
      ;;
    patterns)
      [[ "$heading_hit" -eq 1 ]] && echo "Actionable runbook/procedure matched headings" || echo "Actionable runbook/procedure matched query terms"
      ;;
    knowledge)
      [[ "$heading_hit" -eq 1 ]] && echo "Supporting reference matched headings" || echo "Supporting reference matched query terms"
      ;;
    logs)
      [[ "$heading_hit" -eq 1 ]] && echo "Chronological context matched headings" || echo "Chronological context matched query terms"
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
    echo "Ranking favored heading/section matches in scope \`$scope\`."
  else
    echo "Ranking favored body matches with scope and recency weighting in \`$scope\`."
  fi
}

query_norm=""
intent_boost_decisions=0
intent_boost_projects=0
intent_boost_patterns=0
intent_boost_knowledge=0
intent_boost_logs=0

detect_intent_biases() {
  local q="$1"
  query_norm=" $(printf '%s' "$q" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g; s/[[:space:]]+/ /g') "

  if printf '%s\n' "$query_norm" | grep -Eq '(^| )(how|steps|runbook|procedure|playbook|debug|triage|deploy)( |$)'; then
    intent_boost_patterns=$((intent_boost_patterns + 25))
    intent_boost_logs=$((intent_boost_logs + 10))
  fi

  if [[ "$query_norm" == *" where were we "* ]] || printf '%s\n' "$query_norm" | grep -Eq '(^| )(status|next|continue|blocker|roadmap)( |$)'; then
    intent_boost_projects=$((intent_boost_projects + 35))
    intent_boost_logs=$((intent_boost_logs + 10))
  fi

  if printf '%s\n' "$query_norm" | grep -Eq '(^| )(decision|why|policy|constraint|standard|convention)( |$)'; then
    intent_boost_decisions=$((intent_boost_decisions + 35))
  fi
}

intent_boost_for_scope() {
  case "$1" in
    decisions) echo "$intent_boost_decisions" ;;
    projects) echo "$intent_boost_projects" ;;
    patterns) echo "$intent_boost_patterns" ;;
    knowledge) echo "$intent_boost_knowledge" ;;
    logs) echo "$intent_boost_logs" ;;
    *) echo 0 ;;
  esac
}

tokens=()
token_mode="strict"
strict_tokens=()
fallback_tokens=()

is_stopword() {
  case "$1" in
    the|and|for|with|from|into|onto|over|under|about|above|below|this|that|these|those|a|an|to|of|in|on|at|by|is|are|was|were|be|being|been|do|does|did|as|if|then|than|it|its|our|your|their|we|you|they|i|me|my|us|or|not|no|yes|can|could|should|would|will|may|might|via|per)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_tokens() {
  local q="$1"
  local normalized token normalized_no_space
  local seen_tmp

  # token_mode is used elsewhere (e.g., to decide whether rg -w is safe)
  token_mode="strict"
  tokens=()
  strict_tokens=()
  fallback_tokens=()

  normalized="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g')"

  seen_tmp="$(mktemp)"
  for token in $normalized; do
    [[ -n "$token" ]] || continue

    # Dedup (preserve first-seen order)
    if grep -Fxq -- "$token" "$seen_tmp" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$token" >> "$seen_tmp"

    # Fallback tokens: >=2 chars, no stopword filter
    if [[ "${#token}" -ge 2 ]]; then
      fallback_tokens+=("$token")
    fi

    # Strict tokens: >=3 chars and not stopword
    if [[ "${#token}" -ge 3 ]] && ! is_stopword "$token"; then
      strict_tokens+=("$token")
    fi
  done
  rm -f "$seen_tmp"

  if [[ "${#strict_tokens[@]}" -gt 0 ]]; then
    token_mode="strict"
    tokens=("${strict_tokens[@]}")
  elif [[ "${#fallback_tokens[@]}" -gt 0 ]]; then
    token_mode="fallback"
    tokens=("${fallback_tokens[@]}")
  else
    token_mode="last-resort"
    # Last-resort: take the full normalized query with all non-alnum removed (no spaces),
    # so the token is always matchable in both regex and index() checks.
    normalized_no_space="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+//g')"
    [[ -n "$normalized_no_space" ]] || normalized_no_space="0"
    tokens=("$normalized_no_space")
  fi

  trace "token_mode=${token_mode} tokens=$(IFS=,; printf '%s' "${tokens[*]}")"
}

candidate_files_for_scope() {
  local scope_dir="$1"
  local scope_name strict_count loose_count pattern
  local strict_tmp loose_tmp

  if [[ ! -d "$scope_dir" ]]; then
    return 0
  fi

  scope_name="$(basename "$scope_dir")"
  strict_count=0
  loose_count=0
  strict_tmp="$(mktemp)"
  loose_tmp="$(mktemp)"

  if [[ "${#tokens[@]}" -gt 0 ]]; then
    if command -v rg >/dev/null 2>&1; then
      local cmd tok

      if [[ "$token_mode" == "strict" ]]; then
        cmd=(rg -i -l --no-messages -w)
        for tok in "${tokens[@]}"; do
          cmd+=( -e "$tok" )
        done
        cmd+=("$scope_dir")
        "${cmd[@]}" > "$strict_tmp" 2>/dev/null || true
        strict_count="$(wc -l < "$strict_tmp" | tr -d ' ')"

        if [[ "$strict_count" -eq 0 ]]; then
          cmd=(rg -i -l --no-messages)
          for tok in "${tokens[@]}"; do
            cmd+=( -e "$tok" )
          done
          cmd+=("$scope_dir")
          "${cmd[@]}" > "$loose_tmp" 2>/dev/null || true
          loose_count="$(wc -l < "$loose_tmp" | tr -d ' ')"
          cat "$loose_tmp"
        else
          cat "$strict_tmp"
        fi
      else
        cmd=(rg -i -l --no-messages)
        for tok in "${tokens[@]}"; do
          cmd+=( -e "$tok" )
        done
        cmd+=("$scope_dir")
        "${cmd[@]}" > "$loose_tmp" 2>/dev/null || true
        loose_count="$(wc -l < "$loose_tmp" | tr -d ' ')"
        cat "$loose_tmp"
      fi
    else
      pattern="$(IFS='|'; printf '%s' "${tokens[*]}")"
      if [[ "$token_mode" == "strict" ]]; then
        grep -RilwE -- "$pattern" "$scope_dir" > "$strict_tmp" 2>/dev/null || true
        strict_count="$(wc -l < "$strict_tmp" | tr -d ' ')"
        if [[ "$strict_count" -eq 0 ]]; then
          grep -RilE -- "$pattern" "$scope_dir" > "$loose_tmp" 2>/dev/null || true
          loose_count="$(wc -l < "$loose_tmp" | tr -d ' ')"
          cat "$loose_tmp"
        else
          cat "$strict_tmp"
        fi
      else
        grep -RilE -- "$pattern" "$scope_dir" > "$loose_tmp" 2>/dev/null || true
        loose_count="$(wc -l < "$loose_tmp" | tr -d ' ')"
        cat "$loose_tmp"
      fi
    fi
    trace "scope=${scope_name} candidates_word=${strict_count} candidates_nonword=${loose_count}"
    rm -f "$strict_tmp" "$loose_tmp"
    return 0
  fi

  if command -v rg >/dev/null 2>&1; then
    rg -i -F -l --no-messages -- "$query" "$scope_dir" > "$loose_tmp" 2>/dev/null || true
  else
    grep -RilF -- "$query" "$scope_dir" > "$loose_tmp" 2>/dev/null || true
  fi
  loose_count="$(wc -l < "$loose_tmp" | tr -d ' ')"
  trace "scope=${scope_name} candidates_word=${strict_count} candidates_nonword=${loose_count}"
  cat "$loose_tmp"
  rm -f "$strict_tmp" "$loose_tmp"
}

filename_score() {
  local file="$1"
  local file_norm token score strength

  file_norm=" $(basename "$file" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g') "
  score=0

  for token in "${tokens[@]}"; do
    strength=0
    if [[ "$file_norm" =~ (^|[[:space:]])$token([[:space:]]|$) ]]; then
      strength=10
    elif [[ "$file_norm" =~ (^|[[:space:]])$token[[:alnum:]_]+ ]]; then
      strength=8
    elif [[ "$file_norm" == *"$token"* ]]; then
      strength=6
    fi

    if [[ "$strength" -gt 0 ]]; then
      score=$((score + (60 * strength + 5) / 10))
    fi
  done

  echo "$score"
}

analyze_match_lines() {
  local file="$1"
  local token_blob="$2"

  awk -v token_blob="$token_blob" '
    BEGIN {
      n=split(token_blob, tok, "\t")
      section="other"
      title_points=0
      heading_points=0
      section_points=0
      body_points=0
      heading_hits=0
      title_hits=0
      hits=0
      first=0
    }
    function strength_for_line(line,    i,t,exact_re,prefix_re,s) {
      s=0
      for (i=1; i<=n; i++) {
        t=tok[i]
        if (t=="") continue
        exact_re="(^|[^[:alnum:]_])" t "([^[:alnum:]_]|$)"
        prefix_re="(^|[^[:alnum:]_])" t "[[:alnum:]_]+"
        if (line ~ exact_re) {
          if (s < 10) s=10
          continue
        }
        if (line ~ prefix_re) {
          if (s < 8) s=8
          continue
        }
        if (index(line, t) > 0) {
          if (s < 6) s=6
        }
      }
      return s
    }
    {
      l=tolower($0)

      if (l ~ /^##[[:space:]]+/) {
        section="other"
        if (l ~ /^##[[:space:]]*(decision|consequences|constraints)([[:space:]]|$)/) section="decision"
        else if (l ~ /^##[[:space:]]*(steps|verification|failure modes)([[:space:]]|$)/) section="pattern"
        else if (l ~ /^##[[:space:]]*(status|next|blockers)([[:space:]]|$)/) section="project"
      }

      s=strength_for_line(l)
      if (s == 0) next

      hits++
      if (first == 0) first=NR

      if (NR == 1 && l ~ /^#[[:space:]]+/) {
        loc=60
        title_hits++
      } else if (l ~ /^##[[:space:]]+/) {
        loc=45
        heading_hits++
      } else if (section == "decision" || section == "pattern" || section == "project") {
        loc=55
      } else {
        loc=18
      }

      contrib=int((loc*s + 5)/10)
      if (loc == 60) title_points += contrib
      else if (loc == 45) heading_points += contrib
      else if (loc == 55) section_points += contrib
      else body_points += contrib
    }
    END {
      if (first == 0) first=1
      print title_points "\t" heading_points "\t" section_points "\t" body_points "\t" heading_hits "\t" title_hits "\t" hits "\t" first
    }
  ' "$file" 2>/dev/null
}

apply_match_caps() {
  local title="$1"
  local heading="$2"
  local section="$3"
  local body="$4"
  local overflow reduce total

  if [[ "$body" -gt 60 ]]; then
    body=60
  fi

  total=$((title + heading + section + body))
  overflow=0
  if [[ "$total" -gt 180 ]]; then
    overflow=$((total - 180))
  fi

  if [[ "$overflow" -gt 0 ]]; then
    reduce="$overflow"
    if [[ "$body" -ge "$reduce" ]]; then
      body=$((body - reduce))
      reduce=0
    else
      reduce=$((reduce - body))
      body=0
    fi
    if [[ "$reduce" -gt 0 ]]; then
      if [[ "$section" -ge "$reduce" ]]; then
        section=$((section - reduce))
        reduce=0
      else
        reduce=$((reduce - section))
        section=0
      fi
    fi
    if [[ "$reduce" -gt 0 ]]; then
      if [[ "$heading" -ge "$reduce" ]]; then
        heading=$((heading - reduce))
        reduce=0
      else
        reduce=$((reduce - heading))
        heading=0
      fi
    fi
    if [[ "$reduce" -gt 0 ]]; then
      if [[ "$title" -ge "$reduce" ]]; then
        title=$((title - reduce))
        reduce=0
      else
        title=0
      fi
    fi
  fi

  total=$((title + heading + section + body))
  if [[ "$total" -lt 0 ]]; then
    total=0
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$total" "$title" "$heading" "$section" "$body"
}

recency_score() {
  local scope="$1"
  local file_ts="$2"
  local max_points ratio age_days older_ratio

  max_points="$(recency_max_points "$scope")"
  [[ "$max_points" -gt 0 ]] || { echo 0; return; }

  age_days=$(( (now_epoch - file_ts) / 86400 ))
  if [[ "$age_days" -lt 0 ]]; then
    age_days=0
  fi

  if [[ "$age_days" -le 7 ]]; then
    ratio=100
  elif [[ "$age_days" -le 30 ]]; then
    ratio=70
  elif [[ "$age_days" -le 90 ]]; then
    ratio=40
  else
    older_ratio=10
    if [[ "$scope" == "decisions" ]]; then
      older_ratio=20
    fi
    ratio="$older_ratio"
  fi

  echo $(( max_points * ratio / 100 ))
}

decision_status_score() {
  local file="$1"
  local status

  status="$(grep -m1 -E '^Status:[[:space:]]*' "$file" 2>/dev/null | sed -E 's/^Status:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' || true)"
  status="$(trim "$status")"

  case "$status" in
    accepted|"") echo 40 ;;
    proposed) echo 10 ;;
    deprecated) echo -50 ;;
    *) echo 0 ;;
  esac
}

decision_identity_file=""
decision_has_supersedes_file=""
decision_superseded_file=""
decision_count_indexed=0
decision_superseded_count=0

normalize_supersede_ref() {
  local ref="$1"
  local norm

  norm="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"
  norm="$(trim "$norm")"
  norm="${norm//\`/}"
  norm="$(printf '%s' "$norm" | sed -E "s/^[[:space:]'\"()\[\]{}<]+//; s/[[:space:]'\"()\[\]{}>,;:.]+$//")"
  norm="$(printf '%s' "$norm" | sed -E 's#^\./##; s#^memory/##')"
  printf '%s' "$norm"
}

build_decision_supersede_index() {
  local decisions_dir="$1"
  local file rel base base_noext line rhs ref norm_ref
  local key1 key2 key3 matched_rel

  decision_count_indexed=0
  decision_superseded_count=0

  : > "$decision_identity_file"
  : > "$decision_has_supersedes_file"
  : > "$decision_superseded_file"

  [[ -d "$decisions_dir" ]] || {
    trace "decision_index decisions_scanned=0 superseded_entries=0"
    return 0
  }

  while IFS= read -r file || [[ -n "$file" ]]; do
    [[ -f "$file" ]] || continue
    rel="${file#"$MEMORY_ROOT"/}"
    rel="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
    base="$(basename "$rel")"
    base_noext="${base%.md}"

    printf '%s\t%s\n' "$rel" "$rel" >> "$decision_identity_file"
    printf '%s\t%s\n' "$base" "$rel" >> "$decision_identity_file"
    printf '%s\t%s\n' "$base_noext" "$rel" >> "$decision_identity_file"
    decision_count_indexed=$((decision_count_indexed + 1))
  done < <(find "$decisions_dir" -type f -name '*.md' 2>/dev/null | sort)

  if [[ ! -s "$decision_identity_file" ]]; then
    trace "decision_index decisions_scanned=0 superseded_entries=0"
    return 0
  fi
  sort -u "$decision_identity_file" -o "$decision_identity_file"

  while IFS= read -r file || [[ -n "$file" ]]; do
    [[ -f "$file" ]] || continue
    rel="${file#"$MEMORY_ROOT"/}"
    rel="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"

    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      rhs="${line#Supersedes:}"
      if [[ -z "$(trim "$rhs")" ]]; then
        continue
      fi
      printf '%s\n' "$rel" >> "$decision_has_supersedes_file"

      while IFS= read -r ref || [[ -n "$ref" ]]; do
        norm_ref="$(normalize_supersede_ref "$ref")"
        [[ -n "$norm_ref" ]] || continue

        key1="$norm_ref"
        key2="$(basename "$norm_ref")"
        key3="${key2%.md}"

        matched_rel="$(awk -F $'\t' -v k="$key1" '$1==k {print $2; exit}' "$decision_identity_file" || true)"
        if [[ -z "$matched_rel" ]]; then
          matched_rel="$(awk -F $'\t' -v k="$key2" '$1==k {print $2; exit}' "$decision_identity_file" || true)"
        fi
        if [[ -z "$matched_rel" ]]; then
          matched_rel="$(awk -F $'\t' -v k="$key3" '$1==k {print $2; exit}' "$decision_identity_file" || true)"
        fi

        if [[ -n "$matched_rel" ]]; then
          printf '%s\n' "$matched_rel" >> "$decision_superseded_file"
        fi
      done < <(printf '%s\n' "$rhs" | tr ',' '\n')
    done < <(grep -E '^Supersedes:[[:space:]]*' "$file" 2>/dev/null || true)
  done < <(find "$decisions_dir" -type f -name '*.md' 2>/dev/null | sort)

  if [[ -s "$decision_has_supersedes_file" ]]; then
    sort -u "$decision_has_supersedes_file" -o "$decision_has_supersedes_file"
  fi
  if [[ -s "$decision_superseded_file" ]]; then
    sort -u "$decision_superseded_file" -o "$decision_superseded_file"
    decision_superseded_count="$(wc -l < "$decision_superseded_file" | tr -d ' ')"
  fi

  trace "decision_index decisions_scanned=${decision_count_indexed} superseded_entries=${decision_superseded_count}"
}

decision_supersede_penalty() {
  local file="$1"
  local rel
  local penalty

  penalty=0
  rel="${file#"$MEMORY_ROOT"/}"
  rel="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"

  if [[ -s "$decision_has_supersedes_file" ]] && grep -Fxq -- "$rel" "$decision_has_supersedes_file" 2>/dev/null; then
    penalty=$((penalty - 10))
  fi
  if [[ -s "$decision_superseded_file" ]] && grep -Fxq -- "$rel" "$decision_superseded_file" 2>/dev/null; then
    penalty=$((penalty - 10))
  fi

  echo "$penalty"
}

project_bias_score() {
  local scope="$1"
  local file="$2"
  local project_hint="$3"
  local p_lower p_slug path_lower proj_re

  [[ -n "$project_hint" ]] || { echo 0; return; }

  p_lower="$(printf '%s' "$project_hint" | tr '[:upper:]' '[:lower:]')"
  p_slug="$(slugify "$project_hint")"
  path_lower="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"

  if [[ "$scope" == "projects" ]]; then
    if [[ "$path_lower" == *"/projects/$p_lower/"* || "$path_lower" == *"/projects/$p_slug/"* ]]; then
      echo 50
      return
    fi
  fi

  if [[ "$scope" == "decisions" || "$scope" == "patterns" || "$scope" == "knowledge" ]]; then
    proj_re="$(escape_regex "$project_hint")"
    if grep -Eiq "^(#|##)[[:space:]].*${proj_re}" "$file" 2>/dev/null; then
      echo 20
      return
    fi
    if [[ "$p_slug" != "$p_lower" ]]; then
      proj_re="$(escape_regex "$p_slug")"
      if grep -Eiq "^(#|##)[[:space:]].*${proj_re}" "$file" 2>/dev/null; then
        echo 20
        return
      fi
    fi
  fi

  echo 0
}

spam_penalty() {
  local scope="$1"
  local file="$2"
  local match_score="$3"
  local body_score="$4"
  local hits="$5"
  local heading_hits="$6"
  local lc penalty

  penalty=0
  lc="$(wc -l < "$file" | tr -d ' ')"

  if [[ "$lc" -gt 500 && "$match_score" -gt 0 ]]; then
    if (( body_score * 100 / match_score >= 80 )); then
      penalty=$((penalty - 30))
    fi
  fi

  if [[ "$scope" == "logs" && "$hits" -gt 20 && "$heading_hits" -eq 0 ]]; then
    penalty=$((penalty - 25))
  fi

  echo "$penalty"
}

query=""
scopes_csv="$DEFAULT_SCOPES"
max_items="$DEFAULT_MAX_ITEMS"
since=""
project=""
explain_mode=0

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
    --explain|--debug)
      explain_mode=1
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

if ! [[ "$max_items" =~ ^[0-9]+$ ]]; then
  die "--max-items must be an integer"
fi
if [[ "$max_items" -lt 1 ]]; then
  die "--max-items must be >= 1"
fi
if [[ "$max_items" -gt "$MAX_ITEMS_HARD_CAP" ]]; then
  max_items="$MAX_ITEMS_HARD_CAP"
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
now_epoch="$(date +%s)"

build_tokens "$query"
detect_intent_biases "$query"
token_blob=""
if [[ "${#tokens[@]}" -gt 0 ]]; then
  token_blob="$(IFS=$'\t'; printf '%s' "${tokens[*]}")"
fi

candidates_file="$(mktemp)"
sorted_by_score_file="$(mktemp)"
selected_raw_file="$(mktemp)"
selected_file="$(mktemp)"
all_candidates_scope_tmp="$(mktemp)"
selected_paths_file="$(mktemp)"
decision_identity_file="$(mktemp)"
decision_has_supersedes_file="$(mktemp)"
decision_superseded_file="$(mktemp)"
trap 'rm -f "$candidates_file" "$sorted_by_score_file" "$selected_raw_file" "$selected_file" "$all_candidates_scope_tmp" "$selected_paths_file" "$decision_identity_file" "$decision_has_supersedes_file" "$decision_superseded_file"' EXIT

build_decision_supersede_index "$MEMORY_ROOT/decisions"

for scope in "${scopes[@]}"; do
  scope_dir="$MEMORY_ROOT/$scope"
  [[ -d "$scope_dir" ]] || continue

  : > "$all_candidates_scope_tmp"
  candidate_files_for_scope "$scope_dir" | sort -u > "$all_candidates_scope_tmp"

  while IFS= read -r file || [[ -n "$file" ]]; do
    [[ -f "$file" ]] || continue

    file_ts="$(file_epoch "$file")"
    if [[ -n "$since_epoch" && ( "$scope" == "logs" || "$scope" == "projects" ) ]]; then
      if [[ "$file_ts" -lt "$since_epoch" ]]; then
        continue
      fi
    fi

    analysis="$(analyze_match_lines "$file" "$token_blob")"
    IFS=$'\t' read -r title_points heading_points section_points body_points heading_hits title_hits hit_lines first_line <<< "$analysis"

    file_name_match_score="$(filename_score "$file")"
    title_points=$((title_points + file_name_match_score))
    filename_hit=0
    if [[ "$file_name_match_score" -gt 0 ]]; then
      filename_hit=1
    fi
    title_hit=0
    if [[ "$title_hits" -gt 0 ]]; then
      title_hit=1
    fi

    capped_vals="$(apply_match_caps "$title_points" "$heading_points" "$section_points" "$body_points")"
    IFS=$'\t' read -r match_score match_title match_heading match_section match_body <<< "$capped_vals"

    if [[ "$match_score" -le 0 ]]; then
      continue
    fi

    base_score="$(scope_base_weight "$scope")"
    recency_points="$(recency_score "$scope" "$file_ts")"

    status_score=0
    supersede_penalty=0
    if [[ "$scope" == "decisions" ]]; then
      status_score="$(decision_status_score "$file")"
      supersede_penalty="$(decision_supersede_penalty "$file")"
    fi

    project_bias="$(project_bias_score "$scope" "$file" "$project")"
    intent_bias="$(intent_boost_for_scope "$scope")"
    spam_pen="$(spam_penalty "$scope" "$file" "$match_score" "$match_body" "$hit_lines" "$heading_hits")"

    total_score=$((base_score + match_score + recency_points + status_score + supersede_penalty + project_bias + intent_bias + spam_pen))

    heading_hit=0
    if [[ "$heading_hits" -gt 0 ]]; then
      heading_hit=1
    fi

    threshold="$(scope_threshold "$scope")"
    if [[ "$total_score" -lt "$threshold" ]]; then
      if [[ "$scope" != "decisions" || "$heading_hit" -ne 1 && "$filename_hit" -ne 1 && "$title_hit" -ne 1 ]]; then
        continue
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$total_score" \
      "$(scope_priority "$scope")" \
      "$scope" \
      "$file" \
      "$first_line" \
      "$heading_hit" \
      "$file_ts" \
      "$match_score" \
      "$recency_points" \
      "$status_score" \
      "$project_bias" \
      "$spam_pen" \
      "$filename_hit" \
      "$title_hit" \
      "$base_score" \
      "$intent_bias" \
      "$supersede_penalty" \
      "$match_title" \
      "$match_heading" \
      "$match_section" \
      "$match_body" >> "$candidates_file"
  done < "$all_candidates_scope_tmp"
done

if [[ -s "$candidates_file" ]]; then
  sort -t $'\t' -k1,1nr -k2,2n -k7,7nr -k4,4 "$candidates_file" > "$sorted_by_score_file"
fi

if [[ ! -s "$sorted_by_score_file" ]]; then
  echo "## Retrieved Context"
  echo "- No relevant entries found for query: \"$query\"."
  echo "- Searched scopes: $scopes_display."
  echo
  echo "## Evidence"
  echo "1) None"
  echo "   - No matching files in selected scopes."
  exit 0
fi

selected_count=0
top_decision_line=""
decisions_count=0
projects_count=0
patterns_count=0
knowledge_count=0
logs_count=0

scope_count_get() {
  case "$1" in
    decisions) echo "$decisions_count" ;;
    projects) echo "$projects_count" ;;
    patterns) echo "$patterns_count" ;;
    knowledge) echo "$knowledge_count" ;;
    logs) echo "$logs_count" ;;
    *) echo 0 ;;
  esac
}

scope_count_inc() {
  case "$1" in
    decisions) decisions_count=$((decisions_count + 1)) ;;
    projects) projects_count=$((projects_count + 1)) ;;
    patterns) patterns_count=$((patterns_count + 1)) ;;
    knowledge) knowledge_count=$((knowledge_count + 1)) ;;
    logs) logs_count=$((logs_count + 1)) ;;
  esac
}

auto_add_line() {
  local line="$1"
  local scope file cap current_scope_count
  IFS=$'\t' read -r _score _prio scope file _line _hh _ts _ms _rs _ss _pb _sp _fh _th _base _intent _sup _mt _mh _msx _mb <<< "$line"

  if grep -Fxq -- "$file" "$selected_paths_file" 2>/dev/null; then
    return 0
  fi

  cap="$(scope_cap "$scope")"
  current_scope_count="$(scope_count_get "$scope")"
  if [[ "$current_scope_count" -ge "$cap" ]]; then
    return 0
  fi

  if [[ "$selected_count" -ge "$max_items" ]]; then
    return 0
  fi

  printf '%s\n' "$line" >> "$selected_raw_file"
  printf '%s\n' "$file" >> "$selected_paths_file"
  scope_count_inc "$scope"
  selected_count=$((selected_count + 1))
}

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  IFS=$'\t' read -r score _prio scope _file _line heading_hit _ts _ms _rs _ss _pb _sp filename_hit title_hit _base _intent _sup _mt _mh _msx _mb <<< "$line"
  if [[ "$scope" == "decisions" ]]; then
    decision_threshold="$(scope_threshold "decisions")"
    if [[ "$score" -ge "$decision_threshold" || "$heading_hit" -eq 1 || "$filename_hit" -eq 1 || "$title_hit" -eq 1 ]]; then
      top_decision_line="$line"
      break
    fi
  fi
done < "$sorted_by_score_file"

if [[ -n "$top_decision_line" ]]; then
  auto_add_line "$top_decision_line"
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  auto_add_line "$line"
  if [[ "$selected_count" -ge "$max_items" ]]; then
    break
  fi
done < "$sorted_by_score_file"

if [[ ! -s "$selected_raw_file" ]]; then
  echo "## Retrieved Context"
  echo "- No relevant entries found for query: \"$query\"."
  echo "- Searched scopes: $scopes_display."
  echo
  echo "## Evidence"
  echo "1) None"
  echo "   - No matching files in selected scopes."
  exit 0
fi

sort -t $'\t' -k2,2n -k1,1nr -k7,7nr -k4,4 "$selected_raw_file" > "$selected_file"

echo "## Retrieved Context"
summary_count=0
while IFS=$'\t' read -r score _priority scope file _line heading_hit _ts _ms _rs _ss _pb _sp; do
  summary_count=$((summary_count + 1))
  if [[ "$summary_count" -gt 10 ]]; then
    break
  fi

  rel="${file#"$MEMORY_ROOT"/}"
  heading="$(first_heading "$file")"
  reason="$(summary_reason "$scope" "$heading_hit")"

  if [[ -n "$heading" ]]; then
    echo "- ${reason}: \`${rel}\` (${heading})"
  else
    echo "- ${reason}: \`${rel}\`"
  fi
done < "$selected_file"

echo
echo "## Evidence"
ev_count=0
while IFS=$'\t' read -r _score _priority scope file line heading_hit _ts _ms _rs _ss _pb _sp; do
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

if [[ "$explain_mode" -eq 1 ]]; then
  echo
  echo "## Score Explain"
  ex_count=0
  while IFS=$'\t' read -r final_score _priority scope file _line _heading_hit _ts match_score recency_points status_boost project_boost spam_pen _filename_hit _title_hit scope_base intent_boost supersede_pen match_title match_heading match_section match_body; do
    ex_count=$((ex_count + 1))
    rel="${file#"$MEMORY_ROOT"/}"
    body_total=$((match_section + match_body))
    penalties_total=$((supersede_pen + spam_pen))

    echo "${ex_count}) ${rel}"
    echo "   - scope base: ${scope_base}"
    echo "   - match_score: ${match_score} (title=${match_title} heading=${match_heading} body=${body_total}; section=${match_section} body_text=${match_body})"
    echo "   - recency points: ${recency_points}"
    echo "   - status boost: ${status_boost}"
    echo "   - penalties: supersede=${supersede_pen} spam=${spam_pen} total=${penalties_total}"
    echo "   - boosts: project=${project_boost} intent=${intent_boost}"
    echo "   - final score: ${final_score}"
  done < "$selected_file"
fi
