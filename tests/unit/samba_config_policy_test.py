#!/usr/bin/env python3
"""Render the production Samba config template and assert its access contract."""

from __future__ import annotations

import configparser
import os
import re
from pathlib import Path

import yaml
from jinja2 import Environment, StrictUndefined


ROOT = Path(__file__).resolve().parents[2]
PLAYBOOK = ROOT / "ansible/proxmox/container/samba.file.share.yml"


def find_task(tasks: list[dict], name: str) -> dict:
    for task in tasks:
        if task.get("name") == name:
            return task
        block = task.get("block")
        if isinstance(block, list):
            try:
                return find_task(block, name)
            except LookupError:
                pass
    raise LookupError(name)


with PLAYBOOK.open(encoding="utf-8") as stream:
    play = yaml.safe_load(stream)[0]

template_source = find_task(play["tasks"], "Write managed Samba config")["copy"]["content"]

environment = Environment(undefined=StrictUndefined, keep_trailing_newline=True)
environment.filters["basename"] = os.path.basename
environment.filters["bool"] = bool
environment.filters["regex_replace"] = lambda value, pattern, replacement: re.sub(
    pattern, replacement, str(value)
)

effective = {
    "identity": {
        "workgroup": "WORKGROUP",
        "netbios_name": "FIXTURE",
        "server_string": "Fixture Samba NAS",
        "fruit_model": "Xserve",
    },
    "network": {
        "smb_ports": [445],
        "bind_interfaces_only": True,
        "interfaces": ["lo", "eth1"],
        "allow_subnets": ["10.10.0.0/24"],
    },
    "samba": {
        "map_to_guest": "Bad User",
        "guest_account": "nobody",
        "create_mask": "0660",
        "force_create_mode": "0660",
        "directory_mask": "0770",
        "force_directory_mode": "0770",
        "force_user": "smb-ingest",
        "force_group": "smb-ingest",
        "allocation_roundup_size": 4096,
        "macos_vfs_objects": ["catia", "fruit", "streams_xattr"],
        "fruit_aapl": True,
        "fruit_time_machine": False,
        "fruit_resource": "xattr",
        "fruit_nfs_aces": False,
        "min_protocol": "SMB3_02",
        "max_protocol": "SMB3_11",
        "disable_netbios": True,
        "load_printers": False,
        "guest_mode": True,
    },
    "auth": {"username": "fixture-nas"},
    "shares": {
        "explicit": [
            {
                "path": "/media/ARCHIVE",
                "name": "FIXTURE_DATA",
                "guest_ok": True,
                "writable": True,
                "readable": True,
                "xattr": True,
            }
        ]
    },
}

rendered = environment.from_string(template_source).render(
    proxmox_samba_effective=effective,
    ansible_facts={"hostname": "fixture"},
)

parser = configparser.RawConfigParser(delimiters=("=",), strict=True)
parser.read_string(rendered)

assert parser.sections() == ["global", "FIXTURE_DATA"], parser.sections()
share = parser["FIXTURE_DATA"]
assert share.get("path") == "/media/ARCHIVE"
assert share.get("guest ok") == "yes"
assert share.get("guest only") == "no"
assert share.get("read only") == "yes"
assert share.get("write list") == "fixture-nas"
assert "valid users" not in share
assert "FIXTURE_DATA_RO" not in parser
assert "FIXTURE_DATA_RW" not in parser

print("[samba_config_policy_test][ok] one parsed guest-read/auth-write share")
