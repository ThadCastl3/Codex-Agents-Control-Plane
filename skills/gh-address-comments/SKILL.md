---
name: gh-address-comments
description: Help address review/issue comments on the open GitHub PR for the current branch using gh CLI; verify gh auth first and prompt the user to authenticate if not logged in.
metadata:
  short-description: Address comments in a GitHub PR review
---

# PR Comment Handler

Find the open PR for the current branch and address the authorized comments with gh CLI. Use normal execution; request elevated network access only when the sandbox requires it.

Prereq: run `gh auth status` without printing credentials. If authentication is missing, ask the user to authenticate. If the sandbox blocks the command, retry with the required escalation.

## 1) Inspect comments needing attention
- Run scripts/fetch_comments.py which will print out all the comments and review threads on the PR

## 2) Resolve the authorized scope
- Number all the review threads and comments and provide a short summary of what would be required to apply a fix for it
- Follow the user's existing selection or authorization to address all actionable comments. Ask which numbered comments to address only when that scope remains ambiguous.

## 3) Address authorized comments
- Apply fixes for the authorized comments and run relevant verification.

Notes:
- Distinguish authentication failures from rate limits; re-authenticate only when authentication is actually missing or invalid.
