# GitHub release body template

The exact title and completed body require human approval before publication.
Replace every placeholder and remove instructional text.

Proposed GitHub release title:

```text
X.Y.Z — Concise Feature Name
```

---

## X.Y.Z

Summarize the release in one or two plain-language paragraphs. Explain the
operator-facing outcome and why it matters without centering a local machine
or one user's deployment.

### Scope

- Release range: `<previous-tag>..<candidate-tag>`
- Target lane or feature boundary: `<scope>`
- Published entrypoints: `<paths>`
- Important exclusions: `<out-of-scope behavior>`

### Highlights

- `<highest-signal operator-facing change>`
- `<important workflow, compatibility, or safety improvement>`

### Added

- `<new capability and its purpose>`

### Changed

- `<changed behavior and why it changed>`

### Fixed

- `<corrected behavior and operational impact>`

### Operator workflow and safety

Describe the review, dry-run, authorization, rollback, or verification model
when privileged, destructive, storage, authentication, or network behavior is
included. Remove this section only when it is genuinely inapplicable.

### #COMMIT

`<chosen release commit subject>`

### Notable commits since <previous-tag>

- `<abbreviated-hash>` — `<exact commit subject>`

### Assets

- GitHub-generated source archives for tag `X.Y.Z`
- `<published runtime artifacts, if applicable>`
- No additional binary artifacts
