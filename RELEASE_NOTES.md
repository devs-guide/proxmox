# 0.0.1 (RC) - Proxmox VE 6.4

This RC targets Proxmox VE 6.4 on Debian Buster. It builds an ansible-core 2.15 venv (Python 3.11), hardens networking, and improves web UI access with SAN-aware certs.

## Added
- pveproxy cert regeneration play with IP/hostname SANs and automatic proxy restart.
- Python 3.11 + ansible-core 2.15 venv with pinned `community.general:8.6.0` and passlib.

## Changed
- Merge base/buster/release vars into a single vars file during bootstrap to avoid duplicate-key warnings.
- Prefer venv ansible after it is built; keep the 6.4 playlist order.

## Fixed
- UFW defaults to IPv4-only with LAN allows for SSH (22) and web UI (8006); safer SSH defaults and passlib password hashing to avoid lockouts and deprecation warnings.
