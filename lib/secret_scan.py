#!/usr/bin/env python3
"""Portable, fail-closed secret detection and redaction for memory flows."""
import argparse
import json
import re
import sys

_PRIVATE_KEY = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?"
    r"(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.IGNORECASE)
_RULES = (
    ("HIGH", "Bearer token", re.compile(
        r"\bBearer\s+[A-Za-z0-9._~+/-]{20,}={0,2}", re.IGNORECASE)),
    ("HIGH", "AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("HIGH", "GitHub token", re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("HIGH", "API key-style token", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b")),
    ("LOW", "JWT-like token", re.compile(r"\beyJ[A-Za-z0-9._-]{10,}\b")),
    ("LOW", "Long hex token-like string", re.compile(
        r"(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])")),
)
_ASSIGNMENT = re.compile(
    r"\b(?P<label>[A-Za-z0-9_]*(?:password|passwd|token|secret|api[-_ ]?key)"
    r"[A-Za-z0-9_]*)[\"']?[ \t]*[:=][ \t]*"
    r"(?P<value>\"[^\"\r\n]*\"|'[^'\r\n]*'|"
    r"\[REDACTED(?: PRIVATE KEY BLOCK)?\]|[^\s,;]+)", re.IGNORECASE)


def _redacted_value(value):
    value = value.strip("\"'")
    return not value or value in ("[REDACTED]", "[REDACTED PRIVATE KEY BLOCK]")


def _replace(text):
    findings = []
    high_conf = False

    def note(level, label):
        nonlocal high_conf
        finding = f"{level}: {label}"
        if finding not in findings:
            findings.append(finding)
        high_conf = high_conf or level == "HIGH"

    def private_key(match):
        note("HIGH", "Private key block")
        # Preserve source line numbers when scanning before excerpt selection.
        return "[REDACTED PRIVATE KEY BLOCK]" + "\n" * match.group(0).count("\n")

    text = _PRIVATE_KEY.sub(private_key, text)
    for level, label, pattern in _RULES:
        def redact(match, level=level, label=label):
            note(level, label)
            return "[REDACTED]" + "\n" * match.group(0).count("\n")
        text = pattern.sub(redact, text)

    def assignment(match):
        if _redacted_value(match.group("value")):
            return match.group(0)
        note("LOW", "Secret assignment value")
        prefix = match.group(0)[:match.start("value") - match.start()]
        value = match.group("value")
        quote = value[0] if value[0] in "\"'" else ""
        return prefix + quote + "[REDACTED]" + quote

    return _ASSIGNMENT.sub(assignment, text), findings, high_conf


def scan_text(text, mode="read", allow_redact=False):
    """Return status/redacted_text/findings/high_conf without finding values.

    Read mode always redacts. Write mode blocks high-confidence findings unless
    the caller explicitly sets allow_redact. Both modes return sanitized text.
    """
    if mode not in ("read", "write") or not isinstance(text, str):
        raise ValueError("invalid scanner input")
    redacted, findings, high_conf = _replace(text)
    checked, remaining_findings, _ = _replace(redacted)
    if remaining_findings or checked != redacted:
        raise RuntimeError("incomplete secret redaction")
    status = "redacted" if findings else "pass"
    if mode == "write" and high_conf and not allow_redact:
        status = "blocked"
    return dict(status=status, redacted_text=redacted, findings=findings,
                high_conf=high_conf)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("read", "write"), default="read")
    parser.add_argument("--allow-redact", action="store_true")
    parser.add_argument("--format", choices=("text", "json", "shell"), default="text")
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    try:
        if args.self_check:
            scan_text("")
            return 0
        result = scan_text(sys.stdin.read(), args.mode, args.allow_redact)
        if args.format == "json":
            sys.stdout.write(json.dumps(result))
        elif args.format == "shell":
            sys.stdout.write(f"{result['status']}\n{int(result['high_conf'])}\n"
                             f"{len(result['findings'])}\n")
            for finding in result["findings"]:
                sys.stdout.write(finding + "\n")
            sys.stdout.write(result["redacted_text"])
        else:
            sys.stdout.write(result["redacted_text"])
        return 3 if result["status"] == "blocked" else 0
    except BrokenPipeError:
        return 2
    except Exception:
        # Exception messages can contain input data or secret-bearing paths.
        sys.stderr.write("Error: secret scanner unavailable or failed.\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
