# Case Study: Strength-Reducing Fixnum Division by Invariant Constants

A design case study where the interesting content is not the algorithm but the *defense structure* around it: a compile-time theorem check plus a compile-time verification pass that silently declines the optimization on any doubt. Single commit `c0bc78eb` on branch `pr-magic-divide` (base `6879edf0` vs `upstream/main`), not yet merged into `kb-backend`.

## Motivation

`fx/` with an invariant constant divisor compiles to `idiv`, which the commit message prices at 20–90 cycles. The classic remedy is the Granlund–Montgomery round-up method: replace division by `d` with an unsigned multiply-high by a per-divisor magic constant computed at compile time (here, `mulsax` — the high-half multiply that `s/x86_64.ss` carried commented-out at the corresponding line).

## Design

`build-fx/` already special-cased constant RHS operands: powers of two go through `build-fx/p2` (shift), everything else fell to `idiv`. The change inserts a third possibility into the `[(quote ,d)]` clause — `build-fx/magic` — *after* the power-of-two test, so divisor taxonomy stays explicit: 0 and ±1 are handled by the generic paths, powers of two by shifts, and the rest become candidates for magic division.

The pipeline inside cpprim (`s/cpnanopass`-adjacent authoring, but the code lives in `s/cpprim.ss`):

1. **`magic-divide-constants`** computes the magic for `abs(d)`: with N=64, `l = ceil(log2 ad)`, `m = floor(2^(N+l)/ad) + 1`, side condition `e = ad*m − 2^(N+l) ≤ 2^l` checked **exactly** (integer arithmetic, no floating point). Returns the sign-adjusted 64-bit multiplier, the shift `l`, and the `add?` correction flag (`m ≥ 2^N`). Returns `#f` when the side condition fails.
2. **`magic-divide-verify`** re-derives quotients by exact integer division and compares against the magic sequence over boundary fixnums (0, ±1, ±2, ±d, ±(d±1), ±2d, ±2^60, most-positive/negative- fixnum) plus a deterministic pseudo-random sample. Any mismatch declines the whole optimization to `idiv`.
3. **`build-fx/magic`** emits the sequence as `Lsrc` fragments: untag (`sra` by `fixnum-offset`), sign-mask, `abs` via `logxor`/`-`, materialize the magic as an **immediate** (`(immediate ,msig)` → `movabs`), one `%umulhi`, optional `add` correction, shift, re-sign with the divisor's sign folded in, retag (`sll` by `fixnum-offset`). Temps are let-bound with dead initializers so the register allocator assigns locations; the seq is assembled with list operations because `,@` is not valid inside cpprim templates.

The `%umulhi` value instruction is the only backend addition: `mulsax` (uncommented), `asm-umulhi` copying `%rdx` (the high half) to `%rax`, and a `define-instruction` that pre-colors an unspillable `%rax` and declares `%rdx` killed.

Design decision worth naming: correctness is argued **three times independently** — the theorem (with exact side-condition check), the compile-time re-verification against exact division, and the mats — and the second layer is a *runtime-of-the-compiler* guard, so a wrong magic degrades performance instead of miscompiling. The gate `magic-divide-instruction` (`a6.def #t`, `default.def #f`) keeps all of this off targets that have not opted in.

## Where it lives

Not in the `kb-backend` workspace; anchors are **as of branch `pr-magic-divide`, commit `c0bc78eb`**:

- `s/cpprim.ss:2089-2091` — the `[(quote ,d)]` clause: power-of-two first, then `(build-fx/magic e1 d)`.
- `s/cpprim.ss:2099` — `magic-divide-constants`.
- `s/cpprim.ss:2121` — `magic-divide-verify`.
- `s/cpprim.ss:2150` — `build-fx/magic` (the emitted sequence).
- `s/x86_64.ss:379` — `define-instruction value (umulhi)`; `:1034` — `mulsax` define-op (uncommented); `:1997` — `asm-umulhi`.
- `s/np-languages.ss:761` — `umulhi` declaration; `s/a6.def:15` — `magic-divide-instruction #t`; `s/default.def` — default `#f`.

Nearest `kb-backend` anchors: `build-fx/` still handles only powers of two (`s/cpprim.ss:2085`, clause at `:2089`), and `mulsax` is still commented out (`s/x86_64.ss:1292`).

## Contract / truth-table notes

- No condition flags are consumed or produced: T-1/T-2 are not involved, and the change should say so explicitly rather than acquiring a spurious `jp` in review.
- RULE-SYM's *spirit* appears in sign handling: the divisor's sign and the dividend's sign are folded through explicit branches (`(if (< d 0) msk q)` and the `logxor`/`−` re-sign), so every ± combination is constructed, not assumed symmetric.
- The aliasing hazard (RULE-ALIAS) is sidestepped by construction: no emitter aliasing cases exist because the mid-end hands the backend fresh let-bound temps; the allocator, not the emitter, owns register relationships.
- The `%rdx` kill is a **liveness-contract** bug class, not a flag class: kill info must ride the `inline` at the call site (visible to the allocator while the abs dividend may live in `%rdx`), not the instruction's `asm` node, because liveness runs before instruction expansion. This is the same "who sees what, when" discipline as RULE-UNSPILL's walk ordering.
- Untagging/retagging is `fixnum-offset`-only on this port (raw ≪ 3, no low-bit tag); a `+1` tag copied from boolean-immediate code would produce pointer-tagged garbage. Representation constants must be re-derived per port, never copied with the code.

## Verification

Commit-message claims: "fx.mo, 5_3.mo, and a semantic battery (12 divisors × boundary values × 512 pseudo-random dividends) pass; fasl round-trip verified." Two caveats a reviewer should note:

1. The code's sampling loop runs to `k = 256`, not 512 (`s/cpprim.ss` `magic-divide-verify` on the branch: `(fx= k 256)`); the "512" in the message matches no constant in the diff.
2. The commit adds **no mats**: the battery was an authoring-time check (and the permanent `magic-divide-verify` is its fossil), so per RULE-REACH the landing state has no in-tree mat that fails if the magic path is removed — the in-tree guarantee is value-equivalence only.

Also recorded in the message (verified *during development*, by stepping generated code under `gdb` with `setarch -R`; W^X requires an `mprotect` before the debugger can inspect code): three pre-landing bugs — (a) the magic must be an immediate (`movabs`), not a quoted literal, which compiles to a pointer load and multiplied the boxed value's address; (b) the retagging shift must be `fixnum-offset` only; (c) the `%rdx` kill placement above. These are design-time catches, not a post-mortem; they are listed here because each generalizes (see the contract notes).

Note finally that the commit message itself is truncated mid-word: "gates everything behind magic-divide-instruction (a6.def #t, default" — the closing "#f)" never made it into the message.

## Relationship to KB rules

| Rule | Status / contribution |
|---|---|
| RULE-TRUTH, RULE-TRUTH-NA | Not applicable (flag-free); the case study argues flag-freedom should be *stated*, and this message's truncated state is a counterexample. |
| RULE-SYM | Honored in sign structure: dividend and divisor signs handled by explicit construction for all four combinations. |
| RULE-ALIAS | Avoided by construction (allocator-owned temps, no emitter aliasing dispatch) — a legitimate alternative to the three-case dispatch of the cmov/fpsel emitters. |
| RULE-REACH | **Not met as committed** (no mats); mitigated by the permanent compile-time verifier, which is a second, unusual defense layer: correctness checked at every compile, not only in CI. |
| RULE-UNSPILL (spirit) | The `%rdx` kill bug is the same lesson: allocator-visible metadata must be attached where the allocator looks, before expansion. |
| Checklist C | Follows the capability-bit `.def` pattern exactly. |
| Checklist D | Mostly met: the three gdb-found bugs are labeled as development-time findings, and verification claims are concrete — but the 512-vs-256 mismatch is precisely the kind of unverified number this checklist exists to catch. |
