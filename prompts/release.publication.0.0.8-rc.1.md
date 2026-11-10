# Release publication review index — 0.0.8-rc.1

This file maps each proposed title to the exact Markdown body that must receive
human approval before any GitHub release page is created or edited.

| Release ID | State | Proposed title | Reviewed body |
| --- | --- | --- | --- |
| `313447274` | published | `0.0.1 — Proxmox VE 6.4 Bootstrap` | `prompts/release.reconcile.0.0.1.published.md` |
| `306964808` | draft | `0.0.1 — Proxmox VE 6.4 Bootstrap Draft` | `prompts/release.reconcile.0.0.1.draft.md` |
| `313426372` | published | `0.0.2 — Unified Managed Ansible Runtime` | `prompts/release.reconcile.0.0.2.md` |
| `315501604` | published | `0.0.3 — Proxmox VLAN Automation` | `prompts/release.reconcile.0.0.3.md` |
| `318208911` | published | `0.0.4 — Debian LXC and Samba` | `prompts/release.reconcile.0.0.4.md` |
| `399721018` | published | `0.0.5 — Proxmox Runtime and VM Restore` | `prompts/release.reconcile.0.0.5.md` |
| pending | draft prerelease | `0.0.8-rc.1 — Whole-GPU Passthrough Candidate` | `prompts/release.0.0.8-rc.1.md` |

Release `0.0.6 — ZFS Provisioning` already follows the publication policy and
requires no presentation change.

For every historical edit, preserve the existing tag association, source
commit, draft/prerelease state, and empty asset list. Keep the duplicate
`0.0.1` page as a draft. Do not delete it or publish it.

For the candidate, create an annotated `0.0.8-rc.1` tag at the exact approved
release commit, then create the GitHub release as both draft and prerelease.
Publishing the draft requires a second explicit human confirmation.
