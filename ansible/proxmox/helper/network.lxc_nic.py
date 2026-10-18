#!/usr/bin/env python3
"""Parse and compare Proxmox LXC network-device definitions.

The setup runner, Ansible update/verify playbooks, rollback path, and tests all
invoke this file.  Keep the serialization policy here instead of duplicating
CSV or regular-expression parsers in each caller.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass


KEY_RE = re.compile(r"^[a-z][a-z0-9_]*$")
MAC_RE = re.compile(r"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
CONFIG_NET_RE = re.compile(r"^net[0-9]+:\s*(.*)$")
REQUIRED_KEYS = ("name", "bridge", "firewall", "ip")
GENERATED_KEYS = {"type", "hwaddr"}
ALLOWED_KEYS = set(REQUIRED_KEYS) | GENERATED_KEYS


@dataclass(frozen=True)
class Result:
    status: str
    detail: str

    @property
    def ok(self) -> bool:
        return self.status == "ok"


class DefinitionError(ValueError):
    """Raised when a serialized NIC definition cannot be parsed safely."""


def clean_field(value: str) -> str:
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def emit(result: Result) -> int:
    print(f"{result.status}\t{clean_field(result.detail)}")
    return 0 if result.ok else 1


def parse_definition(value: str) -> dict[str, str]:
    if not value:
        raise DefinitionError("empty definition")

    parsed: dict[str, str] = {}
    for raw_token in value.split(","):
        token = raw_token.strip()
        if not token or "=" not in token:
            raise DefinitionError(f"malformed token: {raw_token!r}")
        key, item_value = token.split("=", 1)
        key = key.strip()
        item_value = item_value.strip()
        if not KEY_RE.fullmatch(key) or not item_value:
            raise DefinitionError(f"malformed key/value token: {raw_token!r}")
        if key in parsed:
            raise DefinitionError(f"duplicate key: {key}")
        parsed[key] = item_value
    return parsed


def validate_expected(expected: dict[str, str]) -> Result:
    missing = [key for key in REQUIRED_KEYS if key not in expected]
    if missing:
        return Result("invalid_expected", f"missing required keys: {','.join(missing)}")

    extras = sorted(set(expected) - set(REQUIRED_KEYS))
    if extras:
        return Result("invalid_expected", f"unexpected expected keys: {','.join(extras)}")

    if expected["firewall"] != "1":
        return Result("invalid_expected", "firewall must be enabled")
    if expected["ip"].lower() == "dhcp":
        return Result("invalid_expected", "DATA-Link IPv4 cannot use DHCP")
    return Result("ok", "expected definition is valid")


def compare_definitions(expected_value: str, actual_value: str) -> Result:
    try:
        expected = parse_definition(expected_value)
    except DefinitionError as exc:
        return Result("invalid_expected", str(exc))

    expected_result = validate_expected(expected)
    if not expected_result.ok:
        return expected_result

    if not actual_value:
        return Result("missing_slot", "network slot is absent")
    try:
        actual = parse_definition(actual_value)
    except DefinitionError as exc:
        return Result("malformed_actual", str(exc))

    route_keys = sorted(key for key in ("gw", "gw6") if key in actual)
    if route_keys:
        return Result("unsafe_data_route", f"gateway keys are forbidden: {','.join(route_keys)}")
    if actual.get("ip", "").lower() == "dhcp" or actual.get("ip6", "").lower() == "dhcp":
        return Result("unsafe_data_route", "DHCP is forbidden on the DATA-Link interface")
    vlan_keys = sorted(key for key in ("tag", "trunks") if key in actual)
    if vlan_keys:
        return Result("vlan_not_allowed", f"untagged DATA-Link forbids: {','.join(vlan_keys)}")
    if actual.get("link_down", "0").lower() in {"1", "yes", "true", "on"}:
        return Result("link_down", "DATA-Link interface is administratively disabled")

    extras = sorted(set(actual) - ALLOWED_KEYS)
    if extras:
        return Result("unexpected_field", f"unexpected keys: {','.join(extras)}")
    if "type" in actual and actual["type"] != "veth":
        return Result("unexpected_type", f"expected type=veth, found type={actual['type']}")
    if "hwaddr" in actual and not MAC_RE.fullmatch(actual["hwaddr"]):
        return Result("invalid_hwaddr", f"invalid generated MAC: {actual['hwaddr']}")

    missing = [key for key in REQUIRED_KEYS if key not in actual]
    if missing:
        return Result("missing_required", f"missing required keys: {','.join(missing)}")
    mismatches = [
        f"{key}:expected={expected[key]} actual={actual[key]}"
        for key in REQUIRED_KEYS
        if actual[key] != expected[key]
    ]
    if mismatches:
        return Result("value_mismatch", "; ".join(mismatches))
    return Result("ok", "semantic LXC DATA-Link definition matches")


def config_has_name(config_text: str, expected_name: str) -> Result:
    malformed: list[str] = []
    for line in config_text.splitlines():
        match = CONFIG_NET_RE.match(line)
        if not match:
            continue
        try:
            definition = parse_definition(match.group(1))
        except DefinitionError as exc:
            malformed.append(str(exc))
            continue
        if definition.get("name") == expected_name:
            return Result("ok", f"found interface name={expected_name}")
    if malformed:
        return Result("malformed_config", "; ".join(malformed))
    return Result("interface_name_missing", f"interface name={expected_name} was not found")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--expected", required=True)
    compare_parser.add_argument("--actual", required=True)

    has_name_parser = subparsers.add_parser("config-has-name")
    has_name_parser.add_argument("--name", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "compare":
        return emit(compare_definitions(args.expected, args.actual))
    if args.command == "config-has-name":
        return emit(config_has_name(sys.stdin.read(), args.name))
    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
