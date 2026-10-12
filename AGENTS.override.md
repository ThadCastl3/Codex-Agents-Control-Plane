# Control plane repository maintenance

This repository's global policy is `AGENTS.md`. If that policy was not loaded
from the installed global symlink, read it before work. This override avoids
loading the same global document again as repository guidance.

Keep upstream `.system` updates separate from authored changes. Do not discard
pre-existing diffs. Validate changes with `bin/verify.sh`, then append material
project continuity through the memory writer. Keep private snapshots and
runtime records in ignored `.private/`.
