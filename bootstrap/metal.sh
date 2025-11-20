#!/usr/bin/env bash
## Main bootstrap entry for bare-metal Debian

set -euo pipefail

# Resolve repo root and helper dir
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${ROOT_DIR}/ansible"
