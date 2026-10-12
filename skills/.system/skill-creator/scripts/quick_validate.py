#!/usr/bin/env python3
"""
Quick validation script for skills - minimal version
"""

import re
import sys
from pathlib import Path

import yaml

MAX_SKILL_NAME_LENGTH = 64


def validate_skill(skill_path):
    """Basic validation of a skill"""
    skill_path = Path(skill_path)

    skill_md = skill_path / "SKILL.md"
    if not skill_md.exists():
        return False, "SKILL.md not found"

    content = skill_md.read_text()
    if not content.startswith("---"):
        return False, "No YAML frontmatter found"

    match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not match:
        return False, "Invalid frontmatter format"

    frontmatter_text = match.group(1)

    try:
        frontmatter = yaml.safe_load(frontmatter_text)
        if not isinstance(frontmatter, dict):
            return False, "Frontmatter must be a YAML dictionary"
    except yaml.YAMLError as e:
        return False, f"Invalid YAML in frontmatter: {e}"

    allowed_properties = {"name", "description", "license", "allowed-tools", "metadata"}

    unexpected_keys = set(frontmatter.keys()) - allowed_properties
    if unexpected_keys:
        allowed = ", ".join(sorted(allowed_properties))
        unexpected = ", ".join(sorted(unexpected_keys))
        return (
            False,
            f"Unexpected key(s) in SKILL.md frontmatter: {unexpected}. Allowed properties are: {allowed}",
        )

    if "name" not in frontmatter:
        return False, "Missing 'name' in frontmatter"
    if "description" not in frontmatter:
        return False, "Missing 'description' in frontmatter"

    name = frontmatter.get("name", "")
    if not isinstance(name, str):
        return False, f"Name must be a string, got {type(name).__name__}"
    name = name.strip()
    if name:
        if not re.match(r"^[a-z0-9-]+$", name):
            return (
                False,
                f"Name '{name}' should be hyphen-case (lowercase letters, digits, and hyphens only)",
            )
        if name.startswith("-") or name.endswith("-") or "--" in name:
            return (
                False,
                f"Name '{name}' cannot start/end with hyphen or contain consecutive hyphens",
            )
        if len(name) > MAX_SKILL_NAME_LENGTH:
            return (
                False,
                f"Name is too long ({len(name)} characters). "
                f"Maximum is {MAX_SKILL_NAME_LENGTH} characters.",
            )

    description = frontmatter.get("description", "")
    if not isinstance(description, str):
        return False, f"Description must be a string, got {type(description).__name__}"
    description = description.strip()
    if description.startswith("[TODO:"):
        return False, "Description contains an unfinished TODO placeholder"
    if description:
        if "<" in description or ">" in description:
            return False, "Description cannot contain angle brackets (< or >)"
        if len(description) > 1024:
            return (
                False,
                f"Description is too long ({len(description)} characters). Maximum is 1024 characters.",
            )

    body = content[match.end() :]
    fence_marker = None
    fence_length = 0
    fence_container_indent = 0
    for line in body.splitlines():
        expanded_line = line.expandtabs(4)
        if fence_marker is not None:
            indent = len(expanded_line) - len(expanded_line.lstrip(" "))
            if expanded_line.strip() and indent < fence_container_indent:
                # Dedenting ends a list container, including an unclosed fence.
                fence_marker = None
                fence_length = 0
                fence_container_indent = 0
            else:
                closing_fence = re.match(
                    rf"^[ ]{{{fence_container_indent},{fence_container_indent + 3}}}"
                    rf"({re.escape(fence_marker)}{{{fence_length},}})[ \t]*$",
                    expanded_line,
                )
                if closing_fence:
                    fence_marker = None
                    fence_length = 0
                    fence_container_indent = 0
                continue

        fence = re.match(
            r"^(?:(?P<container>[ ]{0,3}(?:[-+*]|\d{1,9}[.)])[ ]{1,4})|[ ]{0,3})"
            r"(?P<marker>`{3,}|~{3,})(.*)$",
            expanded_line,
        )
        if fence:
            marker = fence.group("marker")
            fence_marker = marker[0]
            fence_length = len(marker)
            fence_container_indent = len(fence.group("container") or "")
            continue

        if fence_marker is None and re.fullmatch(
            r"[ ]{0,3}\[TODO:[^\n]*\][ \t]*", line
        ):
            return False, "Skill instructions contain an unfinished TODO placeholder"

    return True, "Skill is valid!"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python quick_validate.py <skill_directory>")
        sys.exit(1)

    valid, message = validate_skill(sys.argv[1])
    print(message)
    sys.exit(0 if valid else 1)
