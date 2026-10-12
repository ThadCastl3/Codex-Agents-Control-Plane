# secret-scan

## Purpose
Prevent accidental secret leakage into memory files and outputs by applying a deterministic scan + redaction policy.

## Memory Root
Not memory-location specific; this skill operates on text blobs or files.

## When to Use
- before memory writes (write mode)
- before emitting excerpts from sensitive text (read mode)
- in safety checks / doctor flows

## Inputs
Exactly one input source:
- `--text "<blob>"`
- `--stdin`
- `--file "<path>"`

Optional:
- `--mode write|read` (default `write`)
- `--allow-redact` (write mode override for high-confidence findings)

## Output
Markdown report with:
- `Status: pass|redacted|blocked`
- findings list
- redacted preview (bounded)

Exit codes:
- `0` pass/redacted
- `3` blocked
- `2` argument/validation error

## Policy
- write mode:
  - high-confidence findings => blocked unless `--allow-redact`
  - low-confidence findings => redact + continue
- read mode:
  - redact only; never block

## Runtime and safety

Python 3.11 or newer is required for the complete control plane. Readers sanitize source documents before excerpts and sanitize final stdout/stderr. Writer operations are serialized by a per-memory-root kernel lock, including nested index updates. Immutable publication is exclusive; private entries remain Git-ignored.
