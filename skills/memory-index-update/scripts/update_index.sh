#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/lib/secret_scan.sh"

DEFAULT_MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.config/codex-agents/memory}"

usage() {
  cat <<'EOF'
Usage:
  update_index.sh --change <add-project|add-pattern|add-knowledge> --path "<relative-path>" --description "<one line>" [--title "<title>"] [--section "<Section Name>"] [--date YYYY-MM-DD] [--allow-redact]

Notes:
  - Path must exist under memory root.
  - Path is normalized to relative form in index links.
  - Script is idempotent for existing link targets.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

slug_like() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g; s/ +/ /g; s/^ //; s/ $//')"
  printf '%s' "$s"
}

title_case() {
  local s="$1"
  printf '%s\n' "$s" | awk '
    {
      for (i=1; i<=NF; i++) {
        w=tolower($i)
        $i=toupper(substr(w,1,1)) substr(w,2)
      }
      print
    }'
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

has_fixed() {
  local file="$1"
  local pat="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -Fq -- "$pat" "$file"
  else
    grep -Fq -- "$pat" "$file"
  fi
}

has_exact_line() {
  local file="$1"
  local line="$2"
  grep -Fxq -- "$line" "$file"
}

ensure_index_exists() {
  local index_file="$1"
  if [[ -f "$index_file" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$index_file")"
  cat > "$index_file" <<'EOF'
# Agent Memory Index

This index links durable memory anchors.

## Projects

## Patterns

## Knowledge
EOF
}

ensure_section_exists() {
  local index_file="$1"
  local section="$2"
  if has_exact_line "$index_file" "$section"; then
    return 0
  fi
  printf "\n%s\n" "$section" >> "$index_file"
}

derive_title() {
  local change="$1"
  local rel_path="$2"
  local base human

  case "$change" in
    add-project)
      base="$(printf '%s' "$rel_path" | sed -E 's#^projects/([^/]+)/.*$#\1#')"
      ;;
    *)
      base="$(basename "$rel_path")"
      base="${base%.md}"
      ;;
  esac

  human="$(printf '%s' "$base" | tr '_-' ' ')"
  human="$(title_case "$human")"
  human="$(trim "$human")"
  if [[ -z "$human" ]]; then
    human="Untitled"
  fi
  printf '%s' "$human"
}

extract_line_title() {
  printf '%s\n' "$1" | sed -nE 's/^[[:space:]]*-[[:space:]]*\[([^]]+)\]\([^)]*\).*/\1/p'
}

extract_line_desc() {
  local d
  d="$(printf '%s\n' "$1" | sed -nE 's/^[[:space:]]*-[[:space:]]*\[[^]]+\]\([^)]*\)[[:space:]]*—[[:space:]]*(.*)$/\1/p')"
  printf '%s' "$d"
}

find_section_bounds() {
  local index_file="$1"
  local section="$2"
  local start next_header total

  start="$(awk -v s="$section" '$0==s {print NR; exit}' "$index_file")"
  [[ -n "$start" ]] || return 1

  next_header="$(awk -v st="$start" 'NR>st && /^## / {print NR; exit}' "$index_file")"
  total="$(wc -l < "$index_file" | tr -d ' ')"
  if [[ -n "$next_header" ]]; then
    echo "$start $next_header $total"
  else
    echo "$start $((total + 1)) $total"
  fi
}

insert_line_at() {
  local index_file="$1"
  local after_line="$2"
  local line="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v pos="$after_line" -v ins="$line" '
    { print }
    NR == pos { print ins }
  ' "$index_file" > "$tmp"
  mv "$tmp" "$index_file"
}

change=""
rel_path=""
description=""
title=""
section_override=""
entry_date=""

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --change)
      [[ $# -ge 2 ]] || die "missing value for --change"
      change="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || die "missing value for --path"
      rel_path="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || die "missing value for --description"
      description="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || die "missing value for --title"
      title="$2"
      shift 2
      ;;
    --section)
      [[ $# -ge 2 ]] || die "missing value for --section"
      section_override="$2"
      shift 2
      ;;
    --date)
      [[ $# -ge 2 ]] || die "missing value for --date"
      entry_date="$2"
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

case "$change" in
  add-project|add-pattern|add-knowledge) ;;
  *) die "--change must be one of: add-project, add-pattern, add-knowledge" ;;
esac

rel_path="$(trim "$rel_path")"
description="$(trim "$description")"
title="$(trim "$title")"
section_override="$(trim "$section_override")"

[[ -n "$rel_path" ]] || die "--path is required"
[[ -n "$description" ]] || die "--description is required"

sanitize_into description "description" "$description"
sanitize_into title "title" "$title"
sanitize_into section_override "section" "$section_override"

if [[ -z "$entry_date" ]]; then
  entry_date="$(date "+%Y-%m-%d")"
fi
valid_date "$entry_date" || die "--date must be valid YYYY-MM-DD"

MEMORY_ROOT="$DEFAULT_MEMORY_ROOT"
[[ -d "$MEMORY_ROOT" ]] || die "memory root not found: $MEMORY_ROOT"

if [[ "$rel_path" = /* ]]; then
  case "$rel_path" in
    "$MEMORY_ROOT"/*)
      rel_path="${rel_path#"$MEMORY_ROOT"/}"
      ;;
    *)
      die "--path must be under memory root"
      ;;
  esac
fi
while [[ "$rel_path" == ./* ]]; do
  rel_path="${rel_path#./}"
done

if [[ "$rel_path" == *"../"* || "$rel_path" == "../"* || "$rel_path" == *"/.." || "$rel_path" == ".." ]]; then
  die "--path may not contain parent traversal"
fi

target_path="$MEMORY_ROOT/$rel_path"
[[ -e "$target_path" ]] || die "target path not found under memory root: $rel_path"

case "$change" in
  add-project) default_section="## Projects" ;;
  add-pattern) default_section="## Patterns" ;;
  add-knowledge) default_section="## Knowledge" ;;
esac

if [[ -n "$section_override" ]]; then
  if [[ "$section_override" == "## "* ]]; then
    section="$section_override"
  else
    section="## $section_override"
  fi
else
  section="$default_section"
fi

if [[ -z "$title" ]]; then
  title="$(derive_title "$change" "$rel_path")"
fi
title="$(trim "$title")"
[[ -n "$title" ]] || die "resolved title is empty; provide --title explicitly"

index_file="$MEMORY_ROOT/index.md"
ensure_index_exists "$index_file"
ensure_section_exists "$index_file" "$section"

entry_line="- [${title}](${rel_path}) — ${description}"

existing_matches="$(awk -v p="$rel_path" '
  /^[[:space:]]*-[[:space:]]*\[/ {
    if (index($0, "](" p ")") > 0) {
      print NR "|" $0
    }
  }' "$index_file")"

status="added"
inserted_line="$entry_line"
note=""

if [[ -n "$existing_matches" ]]; then
  exact_present=0
  same_desc_any=0
  same_title_diff_desc=0
  significant_title_diff=0

  new_title_norm="$(slug_like "$title")"
  new_desc="$description"

  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -z "$row" ]] && continue
    line_text="${row#*|}"
    old_title="$(extract_line_title "$line_text")"
    old_desc="$(extract_line_desc "$line_text")"
    old_title_norm="$(slug_like "$old_title")"

    if [[ "$old_title_norm" == "$new_title_norm" && "$old_desc" == "$new_desc" ]]; then
      exact_present=1
    fi

    if [[ "$old_desc" == "$new_desc" ]]; then
      same_desc_any=1
    fi

    if [[ "$old_desc" != "$new_desc" ]]; then
      if [[ "$old_title_norm" == "$new_title_norm" ]]; then
        same_title_diff_desc=1
      else
        significant_title_diff=1
      fi
    fi
  done <<< "$existing_matches"

  if [[ "$exact_present" -eq 1 ]]; then
    status="already-present"
    inserted_line=""
    note="Matching link target/title/description already exists."
  elif [[ "$same_desc_any" -eq 1 ]]; then
    status="already-present"
    inserted_line=""
    note="Path already indexed with equivalent description."
  elif [[ "$same_title_diff_desc" -eq 1 && "$significant_title_diff" -eq 0 ]]; then
    status="already-present"
    inserted_line=""
    note="Path exists with different description and similar title; manual edit recommended."
  elif [[ "$same_title_diff_desc" -eq 1 && "$significant_title_diff" -eq 1 ]]; then
    status="already-present"
    inserted_line=""
    note="Path exists with similar title; not adding duplicate. Manual edit recommended."
  fi
fi

if [[ "$status" == "added" ]]; then
  read -r section_start next_header _total_lines <<< "$(find_section_bounds "$index_file" "$section")"
  last_bullet="$(awk -v st="$section_start" -v nh="$next_header" '
    NR > st && NR < nh && /^[[:space:]]*-[[:space:]]*\[/ { lb=NR }
    END { if (lb) print lb }' "$index_file")"

  if [[ -n "$last_bullet" ]]; then
    insert_after="$last_bullet"
  else
    insert_after="$section_start"
  fi

  insert_line_at "$index_file" "$insert_after" "$entry_line"
fi

echo "## Memory Index Update Report"
echo "- Status: \`$status\`"
echo "- Section: \`${section#\#\# }\`"
echo "- Index file: \`$index_file\`"
echo "- Change type: \`$change\`"
echo "- Date: \`$entry_date\`"
echo
if [[ "$status" == "added" ]]; then
  echo "## Inserted Line"
  echo "- \`$entry_line\`"
else
  echo "## Inserted Line"
  echo "- (none)"
fi
echo
echo "## Notes"
if [[ -n "$note" ]]; then
  echo "- $note"
else
  echo "- Entry was appended without reordering existing index content."
fi
echo
echo "## Warnings"
if [[ "${#REDACTION_NOTES[@]}" -eq 0 ]]; then
  echo "- none"
else
  for w in "${REDACTION_NOTES[@]}"; do
    echo "- $w"
  done
fi
