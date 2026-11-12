# Case Study: `x86-64-level` Capability Gating and the `roundsd` Family

A design case study tracing one optimization through two local branches and its landing in `upstream/main` (which `kb-backend` carries). Performance figures below are from the commit messages, not independent measurements.

## Motivation

At optimize level 3, `flround`/`flfloor`/`flceiling`/`fltruncate` went through foreign libcalls. x86-64's `roundsd` (SSE4.1) performs all four with one instruction; the rounding mode is the immediate's low two bits (0 nearest/even, 1 floor, 2 ceiling, 3 truncate). `b25b40f6` claims 10–30% gains in rounding-hot loops on an i7-8550U (session-dependent), and — unusually honest — reports a **26% regression** in one mixed quantize-and-bucket pipeline (reproduced twice), attributed to microarchitectural branch-history effects of removing the foreign-call barrier, not to the instruction sequence. `d47438bc` keeps that warning "worth noting in review discussion."

## Design

The feature accreted in distinguishable layers; each layer is a separate design decision:

1. **Emitter and gate** (`b25b40f6` on `x86-64-roundsd-flround`, and reworked as `d47438bc` on `pr-roundsd-flround`): a `sse-roundsd-op` emitter fixes the rounding-control immediate at compile time and places the REX byte after the `#x66` prefix and before the `#x0F 3A` escape. A new machine constant `roundsd-instruction` (`a6.def #t`, `default.def #f`) gates the cpprim inlines, following the `popcount-instruction` precedent — so targets without SSE4.1 keep the libcall by default.
2. **Constant folding** — the two branches disagree, and the disagreement is instructive: `b25b40f6`/`e1ffc9df` add a dedicated cp0 folder (`try-fold-flrounding`) and flip `primdata.ss` to `cp02 cp03`; `d47438bc` instead relies on the existing generic `mifoldable` machinery ("no flag changes are needed"), since quoted flonum operands are folded before cpprim ever sees them. The latter is less code and one less special case.
3. **Gate generalization** (`5aa1e423`, mflatt): rename `roundsd-instruction` → `fpround-instruction` and add the arm64 `frint*` family under the same gate — one capability name, two architectures.
4. **Dynamic substitution** (`2f7eae2b`, mflatt): a new relocation `reloc_x86_64_fpround` lets the linker patch the call site to `roundsd xmm0, xmm0, mode` at load time when CPUID reports SSE4.1 (`c/fasl.c` `x86_64_set_cpu_features`, extending the popcount mechanism), with `fpround-slow` library fallbacks per mode. This decouples "compiled for baseline x86-64" from "uses roundsd when present."
5. **Configure-level gating** (`38c855bd`, mflatt): `configure --x86-64-level=<n>` (1 = baseline, 2 = POPCOUNT + SSE4.1), plumbed through an `s/a6-options.def` template containing `(define-constant x86-64-level $(level))`, substituted at build time; the emitter then `constant-case`s `x86-64-level` between a direct `roundsd` and the link-editable call form.

Upstream landed a refined version of the stack — `#1088` (`f83f6f92`, all four ops on x86_64 + AArch64, linker-mediated on x86_64) and `#1092` (`68a0bc5e`, `--x86-64-v<level>` with levels 1–4). `kb-backend` carries both.

## Where it lives

**In the `kb-backend` workspace** (the landed form; gate renamed `fpround-instruction`):

- `s/a6.def:14` / `s/arm64.def:14` — `fpround-instruction #t`.
- `s/a6-options.def:1` — the `$(level)` template; substituted by `add-a6-options`, `s/machine.zuo:79` (records the level in the generated file so a reconfigure rebuilds it).
- `s/cpprim.ss:5067` — `define-inline 3` for the four procedures, `constant-case fpround-instruction`, else libcall.
- `s/x86_64.ss:1419-1422` — `sse.roundsd`/`floorsd`/`ceilingsd`/ `truncsd` define-ops.
- `s/x86_64.ss:2296` — `asm-fpround`, `constant-case x86-64-level`: direct `roundsd` at levels 2+, link-editable call below.
- `s/arm64.ss:481` (`define-instruction value (fpround fpfloor fpceiling fptruncate)`), `s/arm64.ss:1888` (`asm-fpround`).
- The dynamic-substitution half: `c/fasl.c` (`x86_64_set_fpround`, `x86_64_fpround_slow_index`), `s/cmacros.ss` (`reloc_x86_64_fpround`).

**As of the source branches** (not merged in this form):

- `x86-64-roundsd-flround` @ `b25b40f6`: `s/x86_64.ss:661` (`fpround` instruction), `:1114`/`:1130` (emitter, imm fixed to 0), `:1976` (`asm-fpround`); `s/cpprim.ss:5050` (flround inline, gate `roundsd-instruction`); `s/cp0.ss:2908` (`try-fold-flround`); `s/a6.def:14`.
- `x86-64-roundsd-flround` @ `e1ffc9df`: extends to `sse.floorsd`/`ceilingsd`/`truncsd` (`s/x86_64.ss:1132-1134`, `asm-fpround` case dispatch at `:1980`), cp0 folder generalized to all four (`s/cp0.ss` `try-fold-flrounding`), `s/cpprim.ss:5055`.
- `pr-roundsd-flround` @ `38c855bd`: `s/x86_64.ss:654` (the `constant-case x86-64-level` instruction clause), `:1933` (`asm-fpround` two-variant dispatch); `configure:336` (`--x86-64-level=*`); `s/a6-options.def:1`.

## Contract / truth-table notes

The sequence consumes **no condition flags**, so T-1/T-2 play no role; the correctness surface is (a) the SSE4.1 encoding (REX/prefix/immediate placement, per the emitter comment) and (b) operand shapes — the instruction accepts `(y fpmem fpur)`, keeping unboxed flonums unboxed. The interesting contract is *capability*, not flags: the gate exists precisely because `roundsd` traps on pre-SSE4.1 hardware, so the `.def` bit, the linker relocation, and the configure level are three expressions of one invariant — "this instruction only executes where legal" — and the change maintains all three consistently. The `maybe-clear-fp-dest` wrapper matches the other FP emitters (a destination that may alias an operand with an undirected NaN payload must be normalized).

## Verification

Commit-message claims: `b25b40f6` and `e1ffc9df` — "fl.ms and 5_3.ms pass at all optimize levels"; `d47438bc` — mats plus the perf numbers above. The accompanying mats are deliberately shape-aware: variable-argument cases built from `string->number`, `(nan)`, and higher-order bindings (`(let ([f fltruncate]) (f ...))`), which cannot be constant-folded and therefore actually reach the inline path — a value-test-with-path-evidence pattern consistent with `../../04-verification/reachability-rule.md`, authored before that rule was written down. The 26% regression was investigated enough to exonerate the sequence (microarchitectural), and the commit says so — checklist D's verified/inferred distinction in action.

## Relationship to KB rules

| Rule | Status |
|---|---|
| RULE-TRUTH / RULE-TRUTH-NA | Not applicable (no flags); the change should say so rather than cargo-culting a `jp`. |
| RULE-SYM | Operand-order symmetric by construction (unary op); the arm-swap hazard does not arise. |
| Checklist C (.def gating) | This case study *is* the precedent the checklist cites: capability-bit gating with a `default.def #f` fallback, later extended by the `x86-64-level` template — the pattern `ipmin-instruction` and `magic-divide-instruction` then reused. |
| RULE-REACH | Met in spirit by the variable-argument mats (fold-proof operand shapes). |
| RULE-DIFF | Differential reference is the libcall itself: the gate's `else` branch *is* the pre-change code, and the linker-substitution variant runs both forms on the same machine. |

One caveat for reviewers: the perf claims (10–30%, 26% regression, factor-of-three-class effects) originate in the commit messages; treat them as leads for measurement, not as measured results.
