# Feature authoring and parser safety

This guide applies to every runner-backed feature in this repository. Its
purpose is to keep the local source, GitHub Actions fixtures, published Pages
tree, and remote host execution on one implementation path.

## One production source of truth

A parser or normalizer belongs in one production artifact: a runner function,
an Ansible task include, or a dedicated helper. Unit and policy tests execute
that artifact directly. They may use an independent output oracle to inspect
the result, but they must not recreate the input parser with a second regex or
fixture-only implementation.

When an Ansible play needs reusable parsing, place the work in a task include
and pass explicit inputs. Return explicit facts or a result map. The live
playbook and fixture playbook must include the same file. Add that include to
the runner's `FEATURE_SUPPORT_FILES` array so streamed remote execution
downloads it with the playbook and templates.

## Avoid layered regex parsing

Regex text can be interpreted by YAML, Jinja, Python's regex engine, and a
shell before it reaches the intended data. A visually plausible doubled
escape can therefore change a character class. Prefer these approaches in
order:

1. command output designed for scripts or a structured API;
2. exact sysfs/file state checks;
3. field parsing with `awk`, `read`, or an equivalent token parser;
4. a single shared regex only when the input is inherently pattern-based.

Do not use a regex to parse whitespace-delimited interface, route, listener,
or Proxmox configuration records when exact fields are available. Do not use
`regex_search(...) is none` or `is not none`; collect explicit matches or use
a command return code.

If a regex is unavoidable, verify the final pattern at its execution layer.
Do not make CI pass by writing a cleaner copy of the expression in a test.

## Required parser fixtures

Parser-affecting changes cover, where relevant:

- no declaration, one valid declaration, invalid method, and duplicates;
- spaces, tabs, LF, CRLF, inline comments, and blank lines;
- dual-stack records where only one address family is in scope;
- arbitrary valid names containing regex metacharacters;
- values ending in `n`, `r`, `s`, or `t` to expose escape/class mistakes;
- complete legacy managed blocks plus nested, orphaned, or incomplete blocks;
- foreign configuration that the feature must refuse to replace.

Assertions compare complete values. For example, a method parser must return
`manual`, not merely a non-empty prefix such as `ma`.

Generated structured configuration follows the same rule. A hosted fixture
must call the production renderer, parse the emitted YAML or JSON with the
real format parser, and assert the final nesting and value types. Do not test a
handwritten approximation of the expected document or rely only on matching
individual output lines; either approach can miss a valid-looking block that
was appended under the wrong parent key.

## Runner and publication checklist

For each new or changed support artifact:

1. Add it to the owning runner's dependency array.
2. Add required public documentation to `actions/pages.features.txt`.
3. Update local/runtime and published dependency validators.
4. Add a policy test that proves CI invokes the production artifact.
5. Push the feature branch and require the pinned GitHub Actions validation
   environment to pass.
6. Use guarded Pages publication only after validation, then verify the live
   commit marker and every remotely fetched dependency.
7. Keep the change unreleased until the full feature acceptance boundary is
   complete and a release is explicitly approved.

## Ansible defaults and check-mode safety

Do not define an overridable Ansible variable in terms of itself, including a
seemingly guarded expression such as `value: "{{ value | default(...) }}"`.
Recent Ansible/Jinja versions can recurse while resolving the task argument.
Keep immutable defaults under a distinct name, then resolve caller input,
loaded group values, and the default into an explicit `*_effective` fact.
Fixtures must omit at least one optional override so CI executes the fallback
path that production uses.

Check mode must describe a proposed mutation without reporting a real change.
Keep `would_change` and `changed` as separate values, and set `changed` only
after the external mutation command returns successfully. A hosted fixture
must execute the production playbook against fake `pct`/`qm` commands and
prove that check mode never invokes their mutation operations. Validate all
operator-supplied values again in the playbook so a stale or hand-edited plan
cannot bypass the runner's normalizer.

## DATA-Link parser incident

The DATA-Link preflight once parsed the method `manual` as `ma`. The
production regex contained doubled control escapes inside a negated character
class, so the regex excluded the literal letters `n`, `r`, and `t`. CI missed
the defect because its fixture playbook had copied the parser with different
escaping.

The corrective design moved legacy cleanup, interface method parsing, policy,
candidate rendering, and structural validation into one production task
include. Both the runner and tests execute that include. Repository policy now
rejects suspicious doubled control escapes in Jinja regex calls and rejects a
test-local DATA-Link regex parser.

The later ifupdown2 repair path follows the same rule. Baseline diagnostics and
candidate validation are separate: a warning from a complete owned legacy
block may authorize canonical repair, but it is never ignored on the generated
candidate. Both parser-only and reload-plan checks use ifupdown2 no-action mode,
and hosted fixtures execute the same production validation include with dirty,
clean, zero-exit-warning, and nonzero failure cases.

The LXC DATA-Link workflow applies the same production-parser rule to
Proxmox comma-separated NIC definitions. Proxmox can reorder keys and add
generated fields after mutation, so raw-string equality is not a valid
verification or ownership test. One shipped helper defines semantic equality
for update no-ops, verification, recovery, rollback, and fixtures. Tests may
provide serialized inputs and expected statuses, but must not duplicate its
CSV parser or normalize values with test-only regexes. Any feature whose
external tool canonicalizes written state must similarly reuse its production
reader in check, apply, verify, rollback, and CI paths.
