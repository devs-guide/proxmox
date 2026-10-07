#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - \
  "${ROOT}/ansible" \
  "${ROOT}/tests/unit/data_link_policy_test.sh" \
  "${ROOT}/tests/unit/data_link_ifreload_policy_test.sh" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
data_link_test = Path(sys.argv[2])
ifreload_test = Path(sys.argv[3])
identity_test = re.compile(
    r"\bregex_search\("
    r"(?:(?!\bregex_search\().){0,1600}?"
    r"\)\s+is\s+(?:not\s+)?none\b",
    re.DOTALL,
)
doubled_control_escape = re.compile(r"\\\\[nrts]")
regex_call_start = re.compile(r"\bregex_(?:findall|search|replace)\s*\(")


def regex_calls(text):
    """Yield complete Jinja regex filter calls without evaluating YAML quoting."""
    for match in regex_call_start.finditer(text):
        index = match.end()
        depth = 1
        quote = None
        escaped = False
        while index < len(text) and depth:
            char = text[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            elif char in {"'", '"'}:
                quote = char
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            index += 1
        yield match.start(), text[match.start():index]

violations = []
escape_violations = []
for path in sorted(root.rglob("*.yml")):
    text = path.read_text(encoding="utf-8")
    for match in identity_test.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        violations.append(f"{path}:{line}")
    for offset, call in regex_calls(text):
        if doubled_control_escape.search(call):
            line = text.count("\n", 0, offset) + 1
            escape_violations.append(f"{path}:{line}")

if violations:
    print(
        "[ansible_regex_presence_policy_test][error] "
        "regex_search match-existence checks must use explicit match counts:",
        file=sys.stderr,
    )
    for violation in violations:
        print(f"  {violation}", file=sys.stderr)
    raise SystemExit(1)

if escape_violations:
    print(
        "[ansible_regex_presence_policy_test][error] "
        "layered Jinja regex calls must not contain doubled \\n/\\r/\\t/\\s escapes; "
        "use token parsing or a shared production parser:",
        file=sys.stderr,
    )
    for violation in escape_violations:
        print(f"  {violation}", file=sys.stderr)
    raise SystemExit(1)

test_text = data_link_test.read_text(encoding="utf-8")
required_test_markers = (
    'ansible/proxmox/tasks/data-link.candidate.yml',
    'DATA_LINK_TASKS',
    "proxmox_vlan_candidate_results.host.methods == ['manual']",
    "'ma' not in proxmox_vlan_candidate_results.host.methods",
    'tabs_crlf',
)
missing_markers = [marker for marker in required_test_markers if marker not in test_text]
copied_parser_markers = [
    marker
    for marker in ('regex_findall(', 'regex_search(', 'regex_replace(')
    if marker in test_text
]
if missing_markers or copied_parser_markers:
    print(
        "[ansible_regex_presence_policy_test][error] DATA-Link tests must execute "
        "the production task and must not carry a test-local regex parser.",
        file=sys.stderr,
    )
    for marker in missing_markers:
        print(f"  missing marker: {marker}", file=sys.stderr)
    for marker in copied_parser_markers:
        print(f"  copied parser marker: {marker}", file=sys.stderr)
    raise SystemExit(1)

ifreload_test_text = ifreload_test.read_text(encoding="utf-8")
required_ifreload_markers = (
    'ansible/proxmox/tasks/data-link.ifreload.validate.yml',
    'DATA_LINK_IFRELOAD_TASKS',
    'baseline_dirty',
    'candidate_warning',
    'foreign_baseline',
)
missing_ifreload_markers = [
    marker for marker in required_ifreload_markers if marker not in ifreload_test_text
]
if missing_ifreload_markers:
    print(
        "[ansible_regex_presence_policy_test][error] DATA-Link ifreload tests must "
        "execute the production validation task for baseline and candidate cases.",
        file=sys.stderr,
    )
    for marker in missing_ifreload_markers:
        print(f"  missing marker: {marker}", file=sys.stderr)
    raise SystemExit(1)

print(
    "[ansible_regex_presence_policy_test][ok] "
    "regex presence, layered escaping, and production-parser source-of-truth policies passed"
)
PY
