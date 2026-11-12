# Case Study: Branchless `fxmin`/`fxmax` via `cmp + cmovcc`

A design case study (no incident — the bugs were caught before landing). Single commit `edde8f5b` on branch `pr-cmov-fxminmax` (base `a8f47df0` vs `upstream/main`), not yet merged into `kb-backend`.

## Motivation

At optimize level 3 the `fxmin`/`fxmax` inlines compiled to a compare and a **branch** (`s/cpprim.ss` on the branch: `(if ,(%inline < ,e1 ,e2) ,e1 ,e2)`). When the comparison direction is data-dependent (the common case in e.g. heap-size bookkeeping and priority updates), the branch mispredicts and stalls. `cmp + cmovcc` gives the same result branchlessly at ~1 cycle/element. The commit's release-note hunk claims "throughput improves by about a factor of three" in a loop of random fixnum min operations and "unchanged" when the direction is predictable — *source: the commit's own `release_notes/release_notes.stex` hunk, not an independent measurement.*

## Design

Two decisions carry the design:

1. **A new value instruction, not an emitter tweak.** `%ipmin`/`%ipmax` are declared in `np-languages.ss` and selected in cpprim under `ipmin-instruction`, keeping the representation knowledge (`cmovcc` semantics, modrm encoding) inside `s/x86_64.ss` and out of the mid-end. The gate follows the `.def` capability-bit pattern (`a6.def #t`, `default.def #f`), so every other target keeps the branchy `if` form unchanged.

2. **Aliasing dispatch in the emitter, no scratch register.** The register allocator may coalesce `dest` with either source, so `asm-ipminmax` selects one of three sequences by `(equal? dest src1)` / `(equal? dest src2)` / neither, mirroring the later `asm-isel-regs` pattern. For `min`:
   - `dest == src1`: `cmp dest, src2; cmovl src2 -> dest` (`cmp a b` sets flags for `b - a`; `l` fires when `src2 < dest`, i.e. `src2` is the smaller — take it);
   - `dest == src2`: `cmp src1, dest; cmovg src1 -> dest` (take `src1` when it is smaller than the current `dest`);
   - otherwise: preset `dest = src1` (aliases nothing, cannot clobber a live source), then the `dest == src1` case.

`max` swaps `cmovl`/`cmovg`. `cmov-op` takes its `ax-ea-modrm-reg` arguments **swapped relative to `binary-op`**: `CMOVcc` encodes the destination in the modrm reg field and the source as r/m, unlike `mov`/`add`. The commit message documents this as the trap: getting it wrong "silently clobbers the source, and because the compiler's own frame-size bookkeeping uses fxmin/fxmax, the resulting heap corruption surfaces as inscrutable GC failures far from the cause."

## Where it lives

Not in the `kb-backend` workspace; anchors are **as of branch `pr-cmov-fxminmax`, commit `edde8f5b`**:

- `s/x86_64.ss:379` — `define-instruction value (ipmin ipmax)` with `move-related` hints for both arms.
- `s/x86_64.ss:1106` — `(define-op cmovl cmov-op #b1100)` / `(define-op cmovg cmov-op #b1111)`.
- `s/x86_64.ss:1466` — `cmov-op`, with the argument-order comment.
- `s/x86_64.ss:2389` — `asm-ipminmax`, the three-case aliasing dispatch.
- `s/cpprim.ss:2553` — `define-inline 3 fxmin` routed through `(constant-case ipmin-instruction ...)`, `fxmax` below it.
- `s/a6.def:15` (`ipmin-instruction #t`), `s/default.def`, `s/np-languages.ss:767` (`ipmin`/`ipmax` declarations).

Nearest `kb-backend` anchors: the branchy pre-image `define-inline 3 fxmin` is still at `s/cpprim.ss:2553`, and this branch's emitter is the explicit model for the select work — `asm-isel-regs` comments cite it ("every aliasing case is handled here, after the fashion of `asm-ipminmax`", `s/x86_64.ss:2429`).

## Contract / truth-table notes

- The sequence consumes **integer** flags, so it is derivable from T-1 (`../../03-backend/flags-truth-tables.md`): integer comparison is total, there is no unordered column, and no `jp`-style escape can ever be needed — say so rather than adding one (cf. RULE-TRUTH-NA's "say so" clause).
- The condition per aliasing case must be read as "take the *other* operand when it wins the comparison"; the min↔max duality is exactly an arm-swap under R-2 (inverting the condition), so each case was derived for both ops rather than generalized from one — the failure mode R-2 exists to prevent, transferred from NaN semantics to modrm operand order.
- No scratch register is introduced, so the unspillable-walk constraint behind RULE-UNSPILL does not arise; the `move-related` hints merely bias coalescing toward the alias cases that need no preset move.

## Verification

Thin, and this is the honest gap: the commit message states **no** verification (no mats run, no bootstrap round, no trace), and the commit adds **no mats** — the existing `mats/fx.ms` `fxmin`/`fxmax` mats (`mats/fx.ms:1123` in `kb-backend`) exercise value semantics only and would pass equally against the branchy fallback or a wrong-modrm clobber, because they carry no path evidence (the exact vacuity mechanism named in `../../04-verification/reachability-rule.md`). The release-note performance numbers are the commit's own. The only correctness argument in the commit is the modrm-order warning derived from a debugging session.

## Relationship to KB rules

| Rule | Status for this change |
|---|---|
| RULE-TRUTH | Satisfiable: all sequences derive from T-1 cells; the PR text shows the derivation per aliasing case. |
| RULE-SYM | Applicable in operand order: `fxmin(e1,e2)` vs `fxmax`'s swapped comparison, and min↔max inversion — both derived, none silently assumed. |
| RULE-TRUTH-NA | N/A by construction (integer); the commit should *say* that, per the "say so rather than emitting one" clause. |
| RULE-ALIAS | The design's core: three-case `(equal? dest …)` dispatch; the commit message documents the preset-clobber failure mode. |
| RULE-REACH | **Not met as committed**: no mat demonstrates the `ipmin` path is reached, and none would fail if `asm-ipminmax` were deleted. First follow-up should be an S-recipe mat (runtime operands, o=3) with a trace citation, plus a disassembly check for the modrm operand order. |
| Checklist C (.def gating) | Followed exactly: capability-bit pattern, default `#f`. |
| Checklist D | Not met: the commit message distinguishes no verified from inferred claims because it makes essentially no verified claims. |
