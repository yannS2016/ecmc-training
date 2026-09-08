#!/usr/bin/env bash
#
# validate.sh -- check every patch here is a well-formed unified diff.
#
# Catches the two defects that produce the same unhelpful "does not apply":
#
#   1. A blank context line written as a genuinely empty line. Unified diff
#      requires a leading space on EVERY line of a hunk body, blanks included.
#      `diff -u` writes " \n"; hand-written hunks tend to write "\n".
#   2. A hunk header whose declared line counts do not match the body.
#
# Neither is visible by eye, and `git apply` reports both as a context
# mismatch -- which reads like a version problem and is not one.
#
# This validates FORM only. Whether a patch applies to a given checkout is a
# separate question: ../00-bootstrap/apply-patches.sh --check
#
#   ./validate.sh
#
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bad=0
shopt -s nullglob
for f in "$here"/*.patch; do
  awk -f "$here/validate.awk" "$f" || bad=1
done
if [[ $bad -eq 0 ]]; then
  echo
  echo "All patches well-formed."
else
  echo
  echo "Fix the above. Generate hunks with 'diff -u' rather than by hand."
fi
exit $bad
