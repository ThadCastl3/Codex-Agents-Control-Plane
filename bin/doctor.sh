#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_MEMORY_ROOT="$DEFAULT_REPO_ROOT/memory"

usage() {
  cat <<'EOF'
Usage:
  doctor.sh [--repo-root "<path>"] [--memory-root "<path>"]

Checks:
  - Required repository files and directories
  - Codex symlink integrity
  - Core skill script executability
  - Bash syntax validation for core shell scripts
  - Curated memory index structure rules
EOF
}

die_usage() {
  echo "Error: $*" >&2
  exit 2
}

abs_path() {
  local input="$1"
  if [[ -d "$input" ]]; then
    (
      cd "$input"
      pwd -P
    )
    return 0
  fi
  local dir base
  dir="$(cd "$(dirname "$input")" && pwd -P)"
  base="$(basename "$input")"
  printf '%s/%s\n' "$dir" "$base"
}

resolve_link_target_abs() {
  local link_path="$1"
  local raw base_dir
  raw="$(readlink "$link_path")"
  base_dir="$(cd "$(dirname "$link_path")" && pwd -P)"
  if [[ "$raw" == /* ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  (
    cd "$base_dir"
    if [[ "$(dirname "$raw")" != "." ]]; then
      cd "$(dirname "$raw")"
      printf '%s/%s\n' "$(pwd -P)" "$(basename "$raw")"
    else
      printf '%s/%s\n' "$(pwd -P)" "$raw"
    fi
  )
}

REPO_ROOT="$DEFAULT_REPO_ROOT"
MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || die_usage "missing value for --repo-root"
      REPO_ROOT="$2"
      shift 2
      ;;
    --memory-root)
      [[ $# -ge 2 ]] || die_usage "missing value for --memory-root"
      MEMORY_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

[[ -n "$REPO_ROOT" ]] || die_usage "--repo-root must be non-empty"
[[ -n "$MEMORY_ROOT" ]] || die_usage "--memory-root must be non-empty"

REPO_ROOT="$(abs_path "$REPO_ROOT")"
MEMORY_ROOT="$(abs_path "$MEMORY_ROOT")"

declare -a CHECKS=()
declare -a FAILURES=()
declare -a FIX_COMMANDS=()
HAS_FAILURE=0

add_check() {
  local status="$1"
  local check_id="$2"
  local message="$3"
  CHECKS+=("${status}|${check_id}|${message}")
}

add_fix() {
  local cmd="$1"
  local existing
  [[ -n "$cmd" ]] || return 0
  for existing in "${FIX_COMMANDS[@]:-}"; do
    [[ "$existing" == "$cmd" ]] && return 0
  done
  FIX_COMMANDS+=("$cmd")
}

mark_pass() {
  local check_id="$1"
  local message="$2"
  add_check "PASS" "$check_id" "$message"
}

mark_fail() {
  local check_id="$1"
  local message="$2"
  local fix_cmd="${3:-}"
  HAS_FAILURE=1
  add_check "FAIL" "$check_id" "$message"
  FAILURES+=("[${check_id}] ${message}")
  add_fix "$fix_cmd"
}

check_file() {
  local check_id="$1"
  local path="$2"
  local fix_cmd="$3"
  if [[ -f "$path" ]]; then
    mark_pass "$check_id" "file exists: $path"
  else
    mark_fail "$check_id" "missing file: $path" "$fix_cmd"
  fi
}

check_dir() {
  local check_id="$1"
  local path="$2"
  local fix_cmd="$3"
  if [[ -d "$path" ]]; then
    mark_pass "$check_id" "directory exists: $path"
  else
    mark_fail "$check_id" "missing directory: $path" "$fix_cmd"
  fi
}

check_executable() {
  local check_id="$1"
  local path="$2"
  local fix_cmd="$3"
  if [[ ! -f "$path" ]]; then
    mark_fail "$check_id" "missing script: $path" "$fix_cmd"
    return 0
  fi
  if [[ ! -x "$path" ]]; then
    mark_fail "$check_id" "script is not executable: $path" "$fix_cmd"
    return 0
  fi
  mark_pass "$check_id" "script executable: $path"
}

check_bash_syntax() {
  local check_id="$1"
  local path="$2"
  local fix_cmd="$3"
  if [[ ! -f "$path" ]]; then
    mark_fail "$check_id" "cannot lint missing script: $path" "$fix_cmd"
    return 0
  fi
  if bash -n "$path" >/dev/null 2>&1; then
    mark_pass "$check_id" "bash syntax valid: $path"
  else
    mark_fail "$check_id" "bash syntax invalid: $path" "$fix_cmd"
  fi
}

INSTALL_CMD="$REPO_ROOT/bin/install.sh"

check_file "repo.agents" "$REPO_ROOT/AGENTS.md" "ls -la \"$REPO_ROOT\""
check_file "repo.readme" "$REPO_ROOT/README.md" "ls -la \"$REPO_ROOT\""
check_dir "repo.skills" "$REPO_ROOT/skills" "ls -la \"$REPO_ROOT\""
check_dir "repo.memory" "$MEMORY_ROOT" "ls -la \"$(dirname "$MEMORY_ROOT")\""
check_file "memory.index" "$MEMORY_ROOT/index.md" "cat > \"$MEMORY_ROOT/index.md\""
check_file "memory.readme" "$MEMORY_ROOT/README.md" "cat > \"$MEMORY_ROOT/README.md\""

EXPECTED_AGENTS="$(abs_path "$REPO_ROOT/AGENTS.md")"
EXPECTED_SKILLS="$(abs_path "$REPO_ROOT/skills")"
CODEx_AGENTS_LINK="$HOME/.codex/AGENTS.md"
CODEx_SKILLS_LINK="$HOME/.codex/skills"

if [[ -L "$CODEx_AGENTS_LINK" ]]; then
  actual="$(resolve_link_target_abs "$CODEx_AGENTS_LINK")"
  if [[ "$actual" == "$EXPECTED_AGENTS" ]]; then
    mark_pass "symlink.agents" "symlink OK: $CODEx_AGENTS_LINK -> $actual"
  else
    mark_fail "symlink.agents" "symlink drift: $CODEx_AGENTS_LINK -> $actual (expected $EXPECTED_AGENTS)" "$INSTALL_CMD"
  fi
else
  mark_fail "symlink.agents" "missing symlink: $CODEx_AGENTS_LINK" "$INSTALL_CMD"
fi

if [[ -L "$CODEx_SKILLS_LINK" ]]; then
  actual="$(resolve_link_target_abs "$CODEx_SKILLS_LINK")"
  if [[ "$actual" == "$EXPECTED_SKILLS" ]]; then
    mark_pass "symlink.skills" "symlink OK: $CODEx_SKILLS_LINK -> $actual"
  else
    mark_fail "symlink.skills" "symlink drift: $CODEx_SKILLS_LINK -> $actual (expected $EXPECTED_SKILLS)" "$INSTALL_CMD"
  fi
else
  mark_fail "symlink.skills" "missing symlink: $CODEx_SKILLS_LINK" "$INSTALL_CMD"
fi

core_scripts=(
  "skills/secret-scan/scripts/scan.sh"
  "skills/memory-retrieve/scripts/retrieve.sh"
  "skills/memory-write/scripts/write.sh"
  "skills/decision-check/scripts/check.sh"
  "skills/decision-record/scripts/record.sh"
  "skills/project-status/scripts/status.sh"
  "skills/project-update/scripts/update.sh"
  "skills/memory-index-update/scripts/update_index.sh"
  "skills/workflow-plan/scripts/plan.sh"
  "skills/runbook-create/scripts/create.sh"
)

for rel in "${core_scripts[@]}"; do
  check_executable "exec.${rel//\//.}" "$REPO_ROOT/$rel" "chmod +x \"$REPO_ROOT/$rel\""
done

syntax_targets=(
  "lib/secret_scan.sh"
  "skills/secret-scan/scripts/scan.sh"
  "skills/memory-retrieve/scripts/retrieve.sh"
  "skills/memory-write/scripts/write.sh"
  "skills/decision-check/scripts/check.sh"
  "skills/decision-record/scripts/record.sh"
  "skills/project-status/scripts/status.sh"
  "skills/project-update/scripts/update.sh"
  "skills/memory-index-update/scripts/update_index.sh"
  "skills/workflow-plan/scripts/plan.sh"
  "skills/runbook-create/scripts/create.sh"
  "bin/install.sh"
  "bin/doctor.sh"
)

for rel in "${syntax_targets[@]}"; do
  check_bash_syntax "bashn.${rel//\//.}" "$REPO_ROOT/$rel" "bash -n \"$REPO_ROOT/$rel\""
done

index_file="$MEMORY_ROOT/index.md"
if [[ -f "$index_file" ]]; then
  if grep -Fxq "## Projects" "$index_file"; then
    mark_pass "index.projects-header" "contains section: ## Projects"
  else
    mark_fail "index.projects-header" "missing section: ## Projects" "sed -n '1,120p' \"$index_file\""
  fi

  if grep -Fxq "## Patterns" "$index_file"; then
    mark_pass "index.patterns-header" "contains section: ## Patterns"
  else
    mark_fail "index.patterns-header" "missing section: ## Patterns" "sed -n '1,120p' \"$index_file\""
  fi

  if grep -Fxq "## Knowledge" "$index_file"; then
    mark_pass "index.knowledge-header" "contains section: ## Knowledge"
  else
    mark_fail "index.knowledge-header" "missing section: ## Knowledge" "sed -n '1,120p' \"$index_file\""
  fi

  if grep -Eq '^##[[:space:]]+Logs([[:space:]]|$)' "$index_file"; then
    mark_fail "index.no-logs-section" "disallowed section present: ## Logs" "sed -n '1,160p' \"$index_file\""
  else
    mark_pass "index.no-logs-section" "no disallowed ## Logs section"
  fi

  if grep -Eq '\[[^]]+\]\([^)]*logs/' "$index_file"; then
    mark_fail "index.no-logs-links" "disallowed log link(s) found in index.md" "grep -nE '\\[[^]]+\\]\\([^)]*logs/' \"$index_file\""
  else
    mark_pass "index.no-logs-links" "no log-target markdown links in index.md"
  fi
fi

result="pass"
exit_code=0
if [[ "$HAS_FAILURE" -eq 1 ]]; then
  result="fail"
  exit_code=1
fi

echo "## Doctor Report"
echo "- Repo root: \`$REPO_ROOT\`"
echo "- Memory root: \`$MEMORY_ROOT\`"
echo "- Result: \`$result\`"

echo
echo "## Checks"
for row in "${CHECKS[@]}"; do
  status="${row%%|*}"
  rest="${row#*|}"
  check_id="${rest%%|*}"
  message="${rest#*|}"
  echo "- ${status} | ${check_id} | ${message}"
done

echo
echo "## Failures"
if [[ "${#FAILURES[@]}" -eq 0 ]]; then
  echo "- None"
else
  for line in "${FAILURES[@]}"; do
    echo "- $line"
  done
fi

echo
echo "## Fix Commands"
if [[ "${#FIX_COMMANDS[@]}" -eq 0 ]]; then
  echo "- None"
else
  for cmd in "${FIX_COMMANDS[@]}"; do
    echo "- \`$cmd\`"
  done
fi

exit "$exit_code"
