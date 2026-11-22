# Repository agent guidance

## Feature implementation

- Keep hostnames, addresses, interface names, bridge names, device identities,
  CTIDs, VLANs, and storage names discoverable or operator-selected. Never
  commit values copied from one deployment as defaults.
- Treat production runners, task includes, templates, and parsers as the only
  implementation source of truth. Tests must execute those artifacts; they
  must not duplicate their parsing logic in fixture-only YAML, Python, or
  shell code.
- Prefer field/token parsing and structured command output over regexes that
  cross YAML, Jinja, shell, and regex escaping layers. If a regex is truly
  required, keep it in one production artifact and add exact-value fixtures
  for spaces, tabs, CRLF, comments, metacharacters, and token endings such as
  `n`, `r`, `s`, and `t`.
- Every runner dependency belongs in its `FEATURE_PLAYBOOKS` or
  `FEATURE_SUPPORT_FILES` array so local execution, Pages publication, and
  remote execution consume the same graph.
- Validate feature branches with GitHub Actions. Do not substitute an
  unpinned local environment for the repository's pinned CI environment.
- Feature commits may be published to the guarded Pages test channel after CI
  passes. Do not create or edit an official release or tag without explicit
  approval.

See `docs/development/feature-authoring.md` for the complete authoring and
regression checklist and `docs/setup/lxc/samba.zfs.plan` for the DATA-Link
incident history.
