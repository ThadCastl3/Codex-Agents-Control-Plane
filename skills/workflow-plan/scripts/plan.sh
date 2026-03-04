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
  plan.sh --goal "<goal>" --project "<project>" [--title "<title>"] [--constraints "<items>"] [--acceptance-criteria "<items>"] [--date YYYY-MM-DD] [--time HH:MM] [--allow-redact]
  plan.sh --goal "<goal>" --to-pattern [--title "<title>"] [--constraints "<items>"] [--acceptance-criteria "<items>"] [--date YYYY-MM-DD] [--time HH:MM] [--allow-redact]
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
  [[ -n "$out" ]] || out="plan"
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
}

goal=""
project=""
title=""
constraints=""
acceptance=""
entry_date=""
entry_time=""
to_pattern=0

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goal)
      [[ $# -ge 2 ]] || die "missing value for --goal"
      goal="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "missing value for --project"
      project="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || die "missing value for --title"
      title="$2"
      shift 2
      ;;
    --constraints)
      [[ $# -ge 2 ]] || die "missing value for --constraints"
      constraints="$2"
      shift 2
      ;;
    --acceptance-criteria)
      [[ $# -ge 2 ]] || die "missing value for --acceptance-criteria"
      acceptance="$2"
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
    --to-pattern)
      to_pattern=1
      shift
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

goal="$(trim "$goal")"
project="$(trim "$project")"
title="$(trim "$title")"
constraints="$(trim "$constraints")"
acceptance="$(trim "$acceptance")"

[[ -n "$goal" ]] || die "--goal is required"

if [[ "$to_pattern" -eq 1 ]]; then
  [[ -z "$project" ]] || die "--project cannot be used with --to-pattern"
else
  [[ -n "$project" ]] || die "--project is required unless --to-pattern is set"
fi

if [[ -n "$project" && ( "$project" == /* || "$project" == *".."* ) ]]; then
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

sanitize_into goal "goal" "$goal"
sanitize_into project "project" "$project"
sanitize_into title "title" "$title"
sanitize_into constraints "constraints" "$constraints"
sanitize_into acceptance "acceptance-criteria" "$acceptance"

if [[ -z "$title" ]]; then
  if [[ "$to_pattern" -eq 1 ]]; then
    title="Workflow plan: $goal"
  else
    title="${project} workflow plan"
  fi
  sanitize_into title "title" "$title"
fi

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
mkdir -p "$MEMORY_ROOT/projects" "$MEMORY_ROOT/patterns"

constraints_file="$(mktemp)"
acceptance_file="$(mktemp)"
trap 'rm -f "$constraints_file" "$acceptance_file"' EXIT
parse_items_to_file "$constraints" "$constraints_file"
parse_items_to_file "$acceptance" "$acceptance_file"

heading="# $title"
pointer_status="not-applicable"
plan_rel=""
plan_path=""

if [[ "$to_pattern" -eq 1 ]]; then
  base_slug="$(slugify "$title")"
  filename="${base_slug}-plan.md"
  plan_rel="patterns/${filename}"
  plan_path="$MEMORY_ROOT/$plan_rel"
  suffix=2
  while [[ -e "$plan_path" ]]; do
    filename="${base_slug}-plan-${suffix}.md"
    plan_rel="patterns/${filename}"
    plan_path="$MEMORY_ROOT/$plan_rel"
    suffix=$((suffix + 1))
  done
else
  resolve_project_dir "$project" "$MEMORY_ROOT/projects"
  mkdir -p "$PROJECT_DIR/plans"
  file_slug="$(slugify "$title")"
  filename="${entry_date}-${file_slug}.md"
  plan_rel="projects/${RESOLVED_PROJECT}/plans/${filename}"
  plan_path="$MEMORY_ROOT/$plan_rel"
  suffix=2
  while [[ -e "$plan_path" ]]; do
    filename="${entry_date}-${file_slug}-${suffix}.md"
    plan_rel="projects/${RESOLVED_PROJECT}/plans/${filename}"
    plan_path="$MEMORY_ROOT/$plan_rel"
    suffix=$((suffix + 1))
  done
fi

{
  printf "%s\n\n" "$heading"
  printf "Date: %s\n" "$entry_date"
  if [[ "$to_pattern" -eq 0 ]]; then
    printf "Project: %s\n" "$RESOLVED_PROJECT"
  fi
  printf "Goal: %s\n\n" "$goal"

  printf "## Constraints\n"
  if [[ -s "$constraints_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf -- "- %s\n" "$line"
    done < "$constraints_file"
  else
    printf -- "- (none specified)\n"
  fi
  printf "\n"

  printf "## Acceptance Criteria\n"
  if [[ -s "$acceptance_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf -- "- %s\n" "$line"
    done < "$acceptance_file"
  else
    printf -- "- (none specified)\n"
  fi
  printf "\n"

  printf "## Execution Steps\n"
  printf -- "- [ ] Define the smallest safe change set for goal: %s\n" "$goal"
  if [[ -s "$constraints_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf -- "- [ ] Ensure implementation respects constraint: %s\n" "$line"
    done < "$constraints_file"
  fi
  if [[ -s "$acceptance_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf -- "- [ ] Implement and validate criterion: %s\n" "$line"
    done < "$acceptance_file"
  else
    printf -- "- [ ] Implement goal-focused changes and capture expected behavior.\n"
  fi
  printf -- "- [ ] Capture evidence and update durable project memory if scope changes.\n\n"

  printf "## Verification\n"
  printf -- "- [ ] Run targeted checks/tests that cover the changed behavior.\n"
  if [[ -s "$acceptance_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf -- "- [ ] Confirm acceptance criterion is met: %s\n" "$line"
    done < "$acceptance_file"
  fi
  printf -- "- [ ] Confirm no regressions in adjacent workflows.\n\n"

  printf "## Rollback\n"
  printf -- "- [ ] Revert touched files/commits to the last known good state.\n"
  printf -- "- [ ] Re-run baseline verification checks after rollback.\n"
  printf -- "- [ ] Document rollback trigger and restoration evidence.\n\n"

  printf "## Risks\n"
  printf -- "- Constraint drift if implementation shortcuts bypass documented limits.\n"
  printf -- "- Incomplete verification may miss edge-case regressions.\n"
  printf -- "- Scope changes may require a follow-up decision record.\n"
} > "$plan_path"

if [[ "$to_pattern" -eq 0 ]]; then
  project_update_script="$REPO_ROOT/skills/project-update/scripts/update.sh"
  [[ -x "$project_update_script" ]] || die "project-update script missing or not executable: $project_update_script"

  pointer_notes="Plan path: ${plan_rel}
Goal: ${goal}"
  pointer_next="Execute plan at ${plan_rel}"

  pointer_output=""
  pointer_args=(
    --project "$RESOLVED_PROJECT"
    --title "Plan created: $title"
    --status "planned"
    --notes "$pointer_notes"
    --next "$pointer_next"
    --date "$entry_date"
    --time "$entry_time"
  )
  if [[ "$ALLOW_REDACT" -eq 1 ]]; then
    pointer_args+=(--allow-redact)
  fi

  if ! pointer_output="$(MEMORY_ROOT="$MEMORY_ROOT" "$project_update_script" "${pointer_args[@]}" 2>&1)"; then
    echo "$pointer_output" >&2
    echo "Error: failed to append project log pointer for plan." >&2
    exit 1
  fi
  pointer_status="appended"
fi

echo "## Workflow Plan Report"
echo

echo "## Files"
echo "- Created: \`$plan_rel\`"

echo
echo "## Entry"
echo "- Heading: \`$heading\`"
if [[ "$to_pattern" -eq 0 ]]; then
  echo "- Project log pointer: \`$pointer_status\`"
else
  echo "- Project log pointer: \`not-applicable\`"
fi

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
