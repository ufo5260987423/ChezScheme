# Expected-Output Files (`experr*`) and Error-Raising Mats

*Purpose: the mechanics behind `mats/experr-compile-*` / `experr-interpret-*`, what a developer must do when a new mat raises an error at level 0, and how the per-configuration patch files fit together.*

## What the files are

The mats runner compares each configuration's output against a per-configuration expected-output file under `mats/` (copied into the build's `mats/` directory, e.g. `ta6le/mats/experr-compile-0-t-f-f`). The filename encodes the configuration:

```
experr-{compile|interpret}-{optimize-level}-{cp0}-{spi}-{cis}[-{hci}][-{threads}]
```

- `compile` vs `interpret` — whether the mat is compiled or run through the interpreter.
- `optimize-level` — 0 or 3 in the CI matrix. At level 3, argument/result type checks are compiled away, so `error?` subtests become no-ops and typically contribute **no** new lines.
- `cp0` (`cp0=t`), `spi` (`spi=t`), `cis` (`cis=t`), `hci` (`hci=…`), threads — the flag combinations of the test-more matrix. Any error message whose text is flag-invariant (the common case: runtime type-check messages like `fx<: a is not a fixnum`) appears identically under every combination.

## The master + patch structure

`mats/root-experr-compile-0-f-f-f` is the master for the level-0 no-flags configuration. The other configurations' files are derived by applying patch files at test time (observed in CI logs):

```
patch ta6le/mats/experr-compile-0-t-f-f mats/patch-compile-0-t-f-f
patch ta6le/mats/experr-interpret-0-f-t-f mats/patch-interpret-0-f-t-f
```

So the rule when adding a mat that raises at level 0:

1. **Record the exact message(s) in `mats/root-experr-compile-0-f-f-f`** (and the interpret master if the mat also runs interpreted), in mat order.
2. **Decide flag-invariance.** If the message is identical under every flag combination the matrix applies (cp0, spi, cis, hci, threads, interpret — true for runtime type checks), no patch file changes. If a flag changes the message or its presence, the corresponding `patch-*` files must be regenerated too.
3. **Level 3 needs nothing** when the check is compiled away — but verify that, don't assume it: a check that survives at level 3 (library-level assertions) does appear in the `experr-compile-3-*` files.

## Failure mode

A missing or extra message shows up in the summary diff as a bare ed-script hunk against the config's summary, e.g.

```
-------- o=0 hci=503 ctb=(/ (collect-trip-bytes) 64) cl=9 ctb --------
9567d9566
< fx.mo:Bug in mat fx-compare-value-position-select clause 2 at line 405 ...
some output differs from expected
```

`NNdNNN` / `< …` lines name the mat and the configuration; the fix is either a code bug (a real miscompile — the wide-base incident, commit `c3f9762d`, surfaced exactly here) or a missing experr entry (a new error-raising mat — commit `82c8e6cc`). Read the diff direction before touching either side.

## Incidents

- `82c8e6cc` — `fx-compare-safe-op-select` raises four argument errors at level 0; the four messages went into `root-experr-compile-0-f-f-f` only, being flag-invariant. (Two earlier `error?` subtests referenced `f` outside its `let` and tested an unbound-variable error instead of the intended cold path — fixed in the same batch; an `error?` mat that passes for the wrong reason contributes the *wrong* message to experr and still diffs clean, so check the message text, not just the diff.)
- `c3f9762d` — a miscompile surfacing as a missing `Bug in mat` line under test-more's GC-stress configuration only (collect-trip-bytes at 1/64, commonization level 9); test-some stayed green. Config-dependent reachability decides which suite catches a bug; see RULE-EDGE in `review-checklists.md`.
