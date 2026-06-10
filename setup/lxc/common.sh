#!/usr/bin/env bash
## Shared LXC baseline defaults for setup/lxc runners.
##
## Generic LXC common baseline (non-project):
## - root
## - app
## - agent
##
## Non-LXC/proxmox baseline remains in ansible/debian (root/proxmox/agent) and is
## intentionally not pulled into this file.
PROXMOX_LXC_COMMON_BASELINE_USERS="${PROXMOX_LXC_COMMON_BASELINE_USERS:-root app agent}"

