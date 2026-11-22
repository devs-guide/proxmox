# Historical GitHub release audit before 0.0.7

This audit was performed against the live GitHub release pages on 2026-10-07
under [`publication.md`](publication.md). It changes no tag, target commit,
asset, or live release page. Replacement bodies require separate human review
before any `gh release edit` action.

| Page | Proposed title | Tag target | Audit result | Review body |
| --- | --- | --- | --- | --- |
| Published 0.0.1 | `0.0.1 — Proxmox VE 6.4 Bootstrap` | `268976b` | Missing Highlights, `#COMMIT`, notable commits, and Assets. | [`history/0.0.1.md`](history/0.0.1.md) |
| Published 0.0.2 | `0.0.2 — Unified Managed Ansible Runtime` | `d6f251c` | Legacy short-form body missing the required structure and assets statement. | [`history/0.0.2.md`](history/0.0.2.md) |
| Published 0.0.3 | `0.0.3 — Proxmox VLAN Automation` | `e56f349` | Content is complete, but the range uses `HEAD` and the commit list lacks verified hashes and the required heading. | [`history/0.0.3.md`](history/0.0.3.md) |
| Published 0.0.4 | `0.0.4 — Debian LXC and Samba` | `ab9acca` | Content is complete, but the range uses `HEAD` and the commit list lacks verified hashes and the required heading. | [`history/0.0.4.md`](history/0.0.4.md) |
| Published 0.0.5 | `0.0.5 — Proxmox Runtime, Networking, LXC, and VM Restore` | `f2120ee` | Detailed legacy body uses the older heading hierarchy and lacks `#COMMIT` and verified notable commits. | [`history/0.0.5.md`](history/0.0.5.md) |
| Published 0.0.6 | `0.0.6 — ZFS Provisioning` | `a8e2c44` | Meets the current required structure. | No correction proposed. |
| Draft duplicate 0.0.1 | unchanged pending decision | target `main` | Stale draft is not the tagged published page and has no compliant body. | Requires a separate keep/delete decision; do not modify it during historical body reconciliation. |

## Publication gate

Before publishing 0.0.7:

1. Review each replacement title and complete body exactly as stored here.
2. Edit only the corresponding published GitHub release page.
3. Verify its tag, target commit, draft/prerelease state, and assets did not
   change.
4. Resolve the duplicate 0.0.1 draft through a separately approved action.
5. Record the resulting live URLs and verification result in the 0.0.7 release
   review without rewriting these approved bodies.

The proposed 0.0.7 body is maintained separately in [`0.0.7.md`](0.0.7.md).
