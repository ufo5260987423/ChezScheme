# If-Conversion in Industry Compilers: LLVM, GCC, HotSpot

How the mature compilers do what the select work (`x86-64-select`) does, and what that implies for Chez. Facts below were verified against current sources (links at the end) in November 2026.

## 0. Concept mapping

| Chez / x86-64-select | LLVM | GCC |
|---|---|---|
| `select-if` / `select-tail` (`s/cpnanopass.ss:3810`,`:3874`) | `SimplifyCFG::FoldTwoEntryPHINode` (IR level) | `tree-ssa-phiopt.c` (GIMPLE) + `ifcvt.cc` (RTL) |
| `%isel` / `%fpsel` IR instructions | `select` instruction (first-class IR, machine-independent) | no explicit IR op; GIMPLE ternary |
| `asm-isel-bool` (setcc bool materialization) | DAG fold: `select c,1,0` → `setcc` node | `noce_try_store_flag` (`ifcvt.cc:1439`) |
| mflatt's general immediate rule `B+(A−B)·b` | DAGCombiner select arithmetic identities | `noce_try_store_flag_constants` / `noce_try_inverse_constants` (since 2001) |
| `asm-isel-regs` / `asm-isel-imms` | `X86ISelLowering::LowerSELECT` | `noce_try_cmove` + `cmove` insn patterns |
| truth-table T-2 (NaN = else) | ordered/unordered `fcmp` predicate family (`oeq`/`ueq`/`ult`/`uno` …) | reversed/unordered comparison codes |
| (missing) reverse conversion | `X86CmovConversion` + `CodeGenPrepare` | `BRANCH_COST` cost model gating |
| (missing) min/max/abs recognition | `ISD::SMAX/SMIN/…` + InstCombine | `noce_try_minmax` / `noce_try_abs` |

## 1. LLVM

**Middle end: select is an IR instruction; SSA solves operand availability.** `br + two empty blocks + phi(a,b)` folds into one `select i1 %c, ty %a, ty %b`. Arms may be any SSA value — the non-immediate selection mflatt asked for is the default shape. Side-effect constraint, same semantics as Chez's `select-operands-ok?` but a generic predicate instead of a shape whitelist: blocks must be empty to fold at all, and sinking computation into select operands requires `isSafeToSpeculativelyExecute`.

**Boolean materialization is a pure DAG fold.** `select %c, 1, 0` folds into the `setcc` node itself; the zext is free — exactly what `asm-isel-bool` does, but inside a unified select framework rather than a dedicated boolean instruction.

**NaN semantics live in the predicate layer; emitters are ignorant.** `fcmp`'s ordered/unordered predicate family is T-2 promoted to syntax: unordered semantics is expressed by *choosing the predicate*, so the cmov/setcc lowering never needs to know NaN exists. This confirms the post-fix Chez layering (semantics guaranteed by the condition-code derivation rules). Corollary: Chez has no unordered predicates, so fp equality + NaN needs a jp or a branch — dropping `%fpsel=` converges with LLVM practice (`ueq` selected on x86 needs extra sequences anyway).

**The key difference: LLVM has a full reverse conversion.** `X86CmovConversion` (on SSA machine code) converts inner-loop cmov groups *back to branches* when the condition costs more than the average of the two arms plus 25% of the misprediction penalty and conversion reduces loop depth cost. `CodeGenPrepare` does select→branch at IR level (obviously predictable condition, or an expensive sinkable operand). The 2022 RFC "cmov-vs-branch optimization" gives the precise cost model: a cmov costs `CmovLatency + max(CondCost, TrueOperandCost, FalseOperandCost)` — **both arms always execute** — and a cmov whose condition sits on a loop-carried dependence chain accumulates latency per iteration.

## 2. GCC

Two levels, 24 years of RTL if-conversion (`ifcvt.cc`, Rivas 2001). The named converters map one-to-one onto the Chez emitters (source-verified):

```
noce_try_minmax / noce_try_abs        ← the flmin/flmax part of x86-64-isa-upgrade
noce_try_inverse_constants            ← constant pairs that are negations: x = ±A
noce_try_store_flag                   ← asm-isel-bool: if (test) x = 1; else x = 0
noce_try_store_flag_constants         ← mflatt's rule: x = B + (A-B)·b, incl. y+c1/y+c2
noce_try_sign_bit_splat
noce_try_cmove                        ← asm-isel-regs / asm-isel-imms
noce_try_addcc                        ← setcc + add/sub
noce_try_cond_arith / cmove_arith     ← conditional arithmetic
```

Tried in order, each gated by `targetm.noce_conversion_profitable_p`. Note `noce_try_store_flag_constants` *is* the "specialize on immediate-value shapes, not on `#t`/`#f` bit patterns" rule from the #1097 review — GCC has had it from the start. The current Chez work implements only the `#t`/`#f` special case; this is the main gap to industry practice.

## 3. HotSpot C2 (third-party measurement, most valuable lesson)

QuestDB's 2026 measurement of C2's `PhaseIdealLoop::conditional_move`:

- C2 converts only when branch probability falls in **[18.2%, 81.8%]** (x86 defaults) and both sides are ≤ `ConditionalMoveLimit` (3) instructions.
- **Core lesson**: the compiler sees branch *bias* (probability ratio); the hardware charges for *predictability* (misprediction rate). They coincide on typical data and diverge adversarially. Measured on a loop-carried dependence chain: a predictable 50/50 branch converted to cmov ran **2.9× slower**; a random 90/10 kept as branch ran **1.9× slower**.
- The same cmov is wildly different depending on whether the selected value **feeds the next iteration** (carried) or not (independent).

Direct mapping to the #1097 benchmark: its 3× win is the *independent* shape (the selected 1/2 accumulates into `s`, not into the next comparison) — exactly the case where cmov wins. A select feeding the loop-carried chain can invert the result.

## 4. Derivation rules addition: the cost side

[RULE-COST] A branchless select **always executes both arms' computation** (the compare produces flags; the cmov needs both operands live). Its latency is `cmov + max(cond, true-arm, false-arm)`. It beats a branch only when the branch would mispredict often enough: roughly `mispredict_rate > cmov_benefit / misprediction_penalty`. On a loop-carried dependence chain the cmov latency accumulates per iteration — the conservative rule is: *select is for unpredictable, non-carried choices; a select whose result feeds the next iteration's condition or operands is a candidate for reverse conversion.* Chez has no profiler, so any profitability work starts as a structural heuristic (innermost loop + expensive condition), exactly the early `X86CmovConversion` shape.

## 5. Implications for the select work

Aligned with industry: machine-independent select abstraction + backend shape specialization (the layering mflatt required), setcc boolean materialization, NaN = else guaranteed by the condition layer, dropping `%fpsel=`.

Gaps, in industry-precedence order:

1. **General immediate rule** — generalize `B+(A−B)·b` beyond the `strue/sfalse` pair (GCC `noce_try_store_flag_constants`; the review's explicit ask).
2. **min/max/abs recognition** — recognize the `(a < b ? a : b)` select shape and route to min/max-style emission (GCC `noce_try_minmax`; connects the cmov-fxminmax branch).
3. **AArch64 `csel`** — the conversion is backend-independent; already promised in the PR description.
4. **Conservative reverse conversion** — structural heuristic first (loop-carried select + expensive condition → back to branch), profile-based refinement only if Chez ever grows branch weights.
5. **Mixed immediate/uvar operands** — accept by coercing the immediate side to a scratch (the imms clause already presets one); LLVM gets this free from SSA.
6. **safe-operation nested shapes** — the `(if (if (both-fixnums? …) (unsafe-fx< …) (error …)) c d)` nest; needs error-escape recognition, the hardest item, industry practice offers no shortcut.

Do not build yet: profile-driven profitability (no profiler in Chez), unordered FP predicates in the IR (the condition-code model plus the T-2 table is the equivalent apparatus).

## Sources

- LLVM [X86CmovConversion.cpp](https://github.com/llvm/llvm-project/blob/main/llvm/lib/Target/X86/X86CmovConversion.cpp) and its [doxygen header](https://llvm.org/doxygen/X86CmovConversion_8cpp.html) (conversion conditions).
- LLVM RFC [cmov-vs-branch optimization](https://discourse.llvm.org/t/rfc-cmov-vs-branch-optimization/6040) (2022, cost model).
- GCC [ifcvt.cc](https://codebrowser.dev/gcc/gcc/ifcvt.cc.html) (converter list, `STORE_FLAG_VALUE`, `noce_conversion_profitable_p`).
- QuestDB, [The Most Expensive Instruction Might Be… cmov](https://questdb.com/blog/cmov-vs-branch-perf/) (2026, C2 thresholds and carried-vs-independent measurement).
