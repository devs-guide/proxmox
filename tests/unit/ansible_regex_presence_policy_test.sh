#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${ROOT}/ansible/proxmox" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
identity_test = re.compile(
    r"\bregex_search\("
    r"(?:(?!\bregex_search\().){0,1600}?"
    r"\)\s+is\s+(?:not\s+)?none\b",
    re.DOTALL,
)

violations = []
for path in sorted(root.rglob("*.yml")):
    text = path.read_text(encoding="utf-8")
    for match in identity_test.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        violations.append(f"{path}:{line}")

if violations:
    print(
        "[ansible_regex_presence_policy_test][error] "
        "regex_search match-existence checks must use explicit match counts:",
        file=sys.stderr,
    )
    for violation in violations:
        print(f"  {violation}", file=sys.stderr)
    raise SystemExit(1)

print(
    "[ansible_regex_presence_policy_test][ok] "
    "regex match-existence predicates use explicit counts"
)
PY
