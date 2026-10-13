#!/usr/bin/env python3
"""Resolve effective accepted decisions before query ranking (stdlib only)."""

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


def normalize_reference(value):
    value = value.strip().strip("`\"' ")
    link = re.fullmatch(r"\[[^]]*\]\(([^)]+)\)", value)
    if link:
        value = link.group(1)
    value = value.strip().removeprefix("./").removeprefix("memory/")
    return value.casefold()


def decision_metadata(document):
    metadata = {}
    for line in document.splitlines():
        if re.match(r"^##\s", line):
            break
        match = re.match(r"^(Status|Supersedes):\s*(.*?)\s*$", line, re.I)
        if match:
            metadata[match.group(1).lower()] = match.group(2)
    status = metadata.get("status", "unknown").strip().lower()
    if status not in {"accepted", "proposed", "deprecated"}:
        status = "unknown"
    references = []
    for value in metadata.get("supersedes", "").split(","):
        reference = normalize_reference(value)
        if reference and reference not in {"none", "n/a", "(none)"}:
            references.append(reference)
    return status, references


def resolve_decisions(memory_root):
    root = Path(memory_root)
    decisions_dir = root / "decisions"
    if not decisions_dir.is_dir():
        raise ValueError("decisions directory is unavailable")
    if decisions_dir.is_symlink():
        raise ValueError("decisions directory may not be a symbolic link")
    decisions = {}
    aliases = defaultdict(set)
    for filename in sorted(decisions_dir.rglob("*")):
        # A linked replacement must not suppress a real accepted decision and
        # then disappear during candidate filtering. Reject an incomplete or
        # externally sourced policy graph before reading linked metadata.
        if filename.is_symlink():
            raise ValueError("decision tree may not contain symbolic links")
        if filename.suffix != ".md" or not filename.is_file():
            continue
        relative = filename.relative_to(root).as_posix()
        if any(character in relative for character in "\t\r\n"):
            raise ValueError("decision filename contains unsupported control characters")
        status, references = decision_metadata(filename.read_text(encoding="utf-8"))
        decisions[relative] = {"status": status, "references": references}
        for alias in {relative, relative[:-3], filename.name, filename.stem}:
            aliases[alias.casefold()].add(relative)

    # Only accepted replacements have effective edges. Proposed/deprecated
    # declarations remain advisory and cannot remove an accepted constraint.
    edges = {name: set() for name in decisions}
    reverse = {name: set() for name in decisions}
    diagnostics = []
    invalid = set()
    for source, metadata in decisions.items():
        if metadata["status"] != "accepted":
            continue
        for reference in metadata["references"]:
            # Full relative paths are exact; ambiguous basenames must never
            # silently pick one of several decisions.
            candidates = aliases.get(reference, set())
            if len(candidates) != 1:
                problem = "missing" if not candidates else "ambiguous"
                diagnostics.append(f"{problem} supersedes target in {source}")
                invalid.add(source)
                continue
            target = next(iter(candidates))
            edges[source].add(target)
            reverse[target].add(source)

    visiting = []
    visited = set()
    cycles = set()

    def visit(node):
        if node in visiting:
            cycle = tuple(sorted(visiting[visiting.index(node):]))
            if cycle not in cycles:
                cycles.add(cycle)
                diagnostics.append("supersession cycle: " + ", ".join(cycle))
            invalid.update(cycle)
            return
        if node in visited:
            return
        visiting.append(node)
        for target in sorted(edges[node]):
            visit(target)
        visiting.pop()
        visited.add(node)

    for node in decisions:
        visit(node)

    def terminals(node, seen=None):
        seen = set() if seen is None else seen
        if node in seen:
            return set()
        seen = seen | {node}
        if not reverse[node]:
            return {node}
        result = set()
        for replacement in reverse[node]:
            result.update(terminals(replacement, seen))
        return result

    for node in decisions:
        replacements = terminals(node)
        if len(replacements) > 1:
            diagnostics.append(
                "competing effective replacements for " + node + ": "
                + ", ".join(sorted(replacements))
            )
            invalid.update(replacements | {node})

    # An unresolved component must not emit a conveniently chosen constraint.
    frontier = list(invalid)
    while frontier:
        node = frontier.pop()
        for related in edges[node] | reverse[node]:
            if related not in invalid:
                invalid.add(related)
                frontier.append(related)

    result = {}
    for node, metadata in decisions.items():
        if node in invalid:
            state = "unresolved"
        elif reverse[node]:
            state = "superseded"
        elif metadata["status"] == "accepted":
            state = "active"
        else:
            state = "advisory"
        result[node] = {
            "status": metadata["status"],
            "state": state,
            "replacements": sorted(terminals(node)) if state == "superseded" else [],
        }
    return {"decisions": result, "diagnostics": sorted(set(diagnostics))}


def emit_tsv(result):
    for name, metadata in result["decisions"].items():
        print("DECISION", name, metadata["status"], metadata["state"], sep="\t")
        for replacement in metadata["replacements"]:
            print("REPLACEMENT", name, replacement, sep="\t")
    for diagnostic in result["diagnostics"]:
        print("DIAGNOSTIC", diagnostic, sep="\t")


def expand_candidates(memory_root, manifest_file, candidates_file):
    root = Path(memory_root).absolute()
    state = {}
    replacements = defaultdict(set)
    for line in Path(manifest_file).read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if fields[0] == "DECISION":
            state[fields[1]] = fields[3]
        elif fields[0] == "REPLACEMENT":
            replacements[fields[1]].add(fields[2])
    expanded = set()
    for candidate in Path(candidates_file).read_text(encoding="utf-8").splitlines():
        filename = Path(candidate)
        try:
            name = filename.absolute().relative_to(root).as_posix()
        except ValueError:
            continue
        if state.get(name) in {"active", "advisory"}:
            expanded.add((name, name))
        elif state.get(name) == "superseded":
            for replacement in replacements[name]:
                if state.get(replacement) == "active":
                    expanded.add((replacement, name))
    for candidate, source in sorted(expanded):
        print(str(root / candidate), str(root / source), sep="\t")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("memory_root")
    parser.add_argument("--format", choices=("tsv", "json"), default="tsv")
    parser.add_argument("--state")
    parser.add_argument("--expand-candidates")
    args = parser.parse_args()
    try:
        if args.expand_candidates:
            if not args.state:
                parser.error("--expand-candidates requires --state")
            expand_candidates(args.memory_root, args.state, args.expand_candidates)
        else:
            result = resolve_decisions(args.memory_root)
            if args.format == "json":
                print(json.dumps(result, sort_keys=True))
            else:
                emit_tsv(result)
    except (OSError, UnicodeError, ValueError, RecursionError):
        # Never print exception details: filenames/content may contain secrets.
        print("Decision state unavailable: metadata could not be resolved.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
