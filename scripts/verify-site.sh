#!/bin/bash
set -euo pipefail

MKDOCS_BIN="${MKDOCS_BIN:-mkdocs}"
FAILED=0

# Check 1: Strict build
if "$MKDOCS_BIN" build --strict --site-dir "$(mktemp -d)" > /dev/null 2>&1; then
  echo "PASS: Strict build"
else
  echo "FAIL: Strict build"
  FAILED=1
fi

# Check 2: No articles/interview in docs or mkdocs.yml
# Exemption: docs/superpowers/ holds historical planning docs excluded from all checks.
if ! grep -r "articles/interview" docs/ mkdocs.yml 2>/dev/null \
    | grep -v "^docs/superpowers/" \
    | grep -q .; then
  echo "PASS: No articles/interview references"
else
  echo "FAIL: No articles/interview references"
  FAILED=1
fi

# Check 3: No references to the renamed docker-supply-chain.md page.
# Exemptions: docker-supply-chain-platform.md is a different, legitimately-named article;
# docs/superpowers/ holds historical planning docs excluded from all checks.
if ! grep -r "docker-supply-chain" docs/ mkdocs.yml 2>/dev/null \
    | grep -v "docker-supply-chain-platform" \
    | grep -v "^docs/superpowers/" \
    | grep -q .; then
  echo "PASS: No docker-supply-chain references"
else
  echo "FAIL: No docker-supply-chain references"
  FAILED=1
fi

# Check 4: mkdocs.yml contains site_name and no Interview nav group
if grep -q 'site_name: Artur'"'"'s Knowledge Base' mkdocs.yml && ! grep -q 'Interview:' mkdocs.yml; then
  echo "PASS: mkdocs.yml has correct site_name and no Interview nav group"
else
  echo "FAIL: mkdocs.yml has correct site_name and no Interview nav group"
  FAILED=1
fi

# Check 5: Durable Execution nav group has exactly 12 articles/durable-execution entries, including temporal-interview-questions.md
# Scope the search to the group itself: from the "- Durable Execution:" line up to
# (but not including) the next top-level nav group ("^  - ") or EOF, so this doesn't
# depend on Durable Execution being the last nav group.
durable_group=$(awk '
  /^  - Durable Execution:/ { found=1; print; next }
  found && /^  - / { exit }
  found { print }
' mkdocs.yml)
durable_count=$(printf '%s\n' "$durable_group" | grep -c 'articles/durable-execution/' || true)
if [ "$durable_count" -eq 12 ] && printf '%s\n' "$durable_group" | grep -q 'temporal-interview-questions.md'; then
  echo "PASS: Durable Execution nav group has 12 entries including temporal-interview-questions.md"
else
  echo "FAIL: Durable Execution nav group has 12 entries including temporal-interview-questions.md"
  FAILED=1
fi

# Check 6: docs/index.md links articles/durable-execution/temporal-interview-questions.md
if grep -q 'articles/durable-execution/temporal-interview-questions.md' docs/index.md; then
  echo "PASS: docs/index.md links temporal-interview-questions.md"
else
  echo "FAIL: docs/index.md links temporal-interview-questions.md"
  FAILED=1
fi

exit $FAILED
