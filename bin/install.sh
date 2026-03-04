#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR_SCRIPT="$SCRIPT_DIR/doctor.sh"
MEMORY_ROOT="$REPO_ROOT/memory"

usage() {
  cat <<'EOF'
Usage:
  install.sh [--skip-doctor] [--dry-run] [--backup-suffix "<suffix>"]

Options:
  --skip-doctor           Do not run doctor after installation.
  --dry-run               Print planned actions without changing files.
  --backup-suffix <text>  Use a custom backup suffix instead of timestamp.
  -h, --help              Show this help message.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

ensure_no_path_separator() {
  local value="$1"
  local name="$2"
  if [[ "$value" == *"/"* ]]; then
    die "$name must not contain '/'"
  fi
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

choose_backup_path() {
  local target="$1"
  local suffix="$2"
  local candidate n
  candidate="${target}.${suffix}.bak"
  n=2
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="${target}.${suffix}.bak.${n}"
    n=$((n + 1))
  done
  printf '%s\n' "$candidate"
}

DRY_RUN=0
SKIP_DOCTOR=0
BACKUP_SUFFIX=""

if [[ $# -eq 0 ]]; then
  :
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-doctor)
      SKIP_DOCTOR=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --backup-suffix)
      [[ $# -ge 2 ]] || die "missing value for --backup-suffix"
      BACKUP_SUFFIX="$2"
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

if [[ -n "$BACKUP_SUFFIX" ]]; then
  ensure_no_path_separator "$BACKUP_SUFFIX" "--backup-suffix"
fi

[[ -f "$REPO_ROOT/AGENTS.md" ]] || die "missing required file: $REPO_ROOT/AGENTS.md"
[[ -d "$REPO_ROOT/skills" ]] || die "missing required directory: $REPO_ROOT/skills"

declare -a ACTIONS=()
declare -a WARNINGS=()
DOCTOR_STATUS="not-run"
DOCTOR_OUTPUT=""
EXIT_CODE=0

add_action() {
  ACTIONS+=("$1")
}

add_warning() {
  WARNINGS+=("$1")
}

backup_existing_path() {
  local target="$1"
  local suffix candidate
  if [[ -n "$BACKUP_SUFFIX" ]]; then
    suffix="$BACKUP_SUFFIX"
  else
    suffix="$(date "+%Y%m%d%H%M%S")"
  fi
  candidate="$(choose_backup_path "$target" "$suffix")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "Would backup \`$target\` -> \`$candidate\`"
    return 0
  fi
  mv "$target" "$candidate"
  add_action "Backed up \`$target\` -> \`$candidate\`"
}

ensure_codex_dir() {
  local codex_dir="$HOME/.codex"
  if [[ -e "$codex_dir" && ! -d "$codex_dir" ]]; then
    backup_existing_path "$codex_dir"
  fi
  if [[ -d "$codex_dir" ]]; then
    add_action "Directory already present: \`$codex_dir\`"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "Would create directory: \`$codex_dir\`"
  else
    mkdir -p "$codex_dir"
    add_action "Created directory: \`$codex_dir\`"
  fi
}

reconcile_link() {
  local target="$1"
  local source="$2"
  local source_abs actual_abs
  source_abs="$(abs_path "$source")"

  if [[ -L "$target" ]]; then
    actual_abs="$(resolve_link_target_abs "$target")"
    if [[ "$actual_abs" == "$source_abs" ]]; then
      add_action "Symlink already correct: \`$target\` -> \`$source_abs\`"
      return 0
    fi
    backup_existing_path "$target"
  elif [[ -e "$target" ]]; then
    backup_existing_path "$target"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    add_action "Would create symlink: \`$target\` -> \`$source_abs\`"
    return 0
  fi

  ln -s "$source_abs" "$target"
  add_action "Created symlink: \`$target\` -> \`$source_abs\`"
}

ensure_codex_dir
reconcile_link "$HOME/.codex/AGENTS.md" "$REPO_ROOT/AGENTS.md"
reconcile_link "$HOME/.codex/skills" "$REPO_ROOT/skills"

if [[ "$SKIP_DOCTOR" -eq 1 ]]; then
  DOCTOR_STATUS="skipped"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  DOCTOR_STATUS="skipped-dry-run"
  add_warning "Doctor not run during dry-run. Execute \`bin/doctor.sh\` after real install."
else
  if [[ ! -x "$DOCTOR_SCRIPT" ]]; then
    DOCTOR_STATUS="failed"
    DOCTOR_OUTPUT="doctor script is missing or not executable: $DOCTOR_SCRIPT"
    EXIT_CODE=1
  else
    set +e
    DOCTOR_OUTPUT="$("$DOCTOR_SCRIPT" --repo-root "$REPO_ROOT" --memory-root "$MEMORY_ROOT" 2>&1)"
    doctor_rc=$?
    set -e
    if [[ "$doctor_rc" -eq 0 ]]; then
      DOCTOR_STATUS="passed"
    else
      DOCTOR_STATUS="failed"
      EXIT_CODE=1
    fi
  fi
fi

echo "## Install Report"
echo "- Repo root: \`$REPO_ROOT\`"
echo "- Dry run: \`$([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)\`"
echo "- Skip doctor: \`$([[ "$SKIP_DOCTOR" -eq 1 ]] && echo yes || echo no)\`"

echo
echo "## Actions"
if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
  echo "- None"
else
  for line in "${ACTIONS[@]}"; do
    echo "- $line"
  done
fi

echo
echo "## Post-Install Validation"
echo "- Status: \`$DOCTOR_STATUS\`"
if [[ -n "$DOCTOR_OUTPUT" ]]; then
  echo
  echo '```text'
  echo "$DOCTOR_OUTPUT"
  echo '```'
fi

echo
echo "## Warnings"
if [[ "${#WARNINGS[@]}" -eq 0 ]]; then
  echo "- None"
else
  for line in "${WARNINGS[@]}"; do
    echo "- $line"
  done
fi

exit "$EXIT_CODE"
