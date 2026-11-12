# The x86_64 Backend: Three Sections and the Select Family Contract Cards

*Purpose: a guided read of `s/x86_64.ss` — registers, instruction selection, assembler — plus the full contract cards for the `isel`/ `fpsel` select family, the reference example for layer-1 design contracts in this knowledge base (`../README.md`). All other `<arch>.ss` files (arm64, riscv64, loongarch64, ppc32, arm32, pb) have the same three-section structure; only the contents differ. Line numbers track the current `sel-stage3` checkout.*

## Section 1: registers (`s/x86_64.ss:14-90`)

Two `define-registers` invocations selected by `(if-feature windows …)`: a Windows (first) and a SysV variant. The macro itself is `define-registers` at `s/np-register.ss:104`; it builds `regvec`, `arg-registers`, `extra-registers`, `extra-fpregisters`, and `real-register?` from three groups: `reserved`, `allocable`, `machine-dependent`.

Each entry is `[name alias… callee-save? mdinfo type]`:

- **Reserved** (`s/x86_64.ss:16-21`, SysV `:57-62`) — never allocated:
  - `%tc` = `%r14` — the thread context pointer (always live).
  - `%sfp` = `%r13` — the Scheme frame pointer.
  - `%ap` = `%rdi` on Windows (:19), `%r9` on SysV (:59) — the allocation pointer, which doubles as a C ABI argument register (`%Carg6` on SysV) because allocation-pointer exposure (`np-expose-allocation-pointer`) models it explicitly around calls.
- **Allocable** — the register allocator's pool. Notable aliases:
  - `%ts` = `%rax` = **`%Cretval`** (:32 / :74) — integer C return value, also the Scheme temp `%ts`.
  - `%Carg1..%Carg4` map to the C integer argument registers — Windows: `%rcx` `%Carg1` (:42), `%rdx` `%Carg2` (:39), `%r8` `%Carg3` (:40), `%r9` `%Carg4` (:41); SysV: `%rdi` `%Carg1`, `%rsi` `%Carg2`, `%rdx` `%Carg3`, `%rcx` `%Carg4` (:70-73). The comment on `:42` explains the ordering: `%rcx` is listed last "to avoid use as a Scheme argument".
  - `%fp1..%fp8` — the allocator's FP pool; `%Cfparg*` live in the machine-dependent group below.
- **Machine-dependent** (`:49-55`, `:82-90`) — not allocator-managed:
  - `%Cfparg1..%Cfparg8` = xmm0-7 (SysV) / xmm0-3 + note (:82-88). `%Cfparg1` doubles as `%Cfpretval` (:82). The SysV comment notes "no FP registers are callee-save"; the Windows comment explains xmm0-5 are caller-save and xmm6-15 callee-save (:49-54).
  - `%sp` — the C stack pointer.

The **C ABI aliases are the single source of truth** for the foreign call sequence: `s/foreign.ss` and the C side (`c/foreign.c`, `c/ffi.c`) both consume the same constants via the generated headers (`s/mkheader.ss`), so the alias table you are reading is the ABI contract, not a convenience naming.

## Section 2: instruction selection (`s/x86_64.ss:94-1165`)

`module` header at `:94-100` exports `md-handle-jump`, `mem->mem`, `fpmem->fpmem`, `coercible?`, `coerce-opnd`, `acsame-mem`, `acsame-ur`. Its job is to answer one question per IR instruction: *can these operands reach the assembler, and if not, how do I coerce them?*

- `coercible?` (`:154`, a macro) and `coerce-opnd` (`:167`) test and fix up operand classes (`mem`, `fpmem`, `ur`, `fpur`). Memory-to-memory operations are split via `mem->mem` (`:140-150`), which introduces a scratch register with a plain `set!` before the self-referential `asm` — the pattern behind RULE-UNSPILL (see [instruction-selection.md](instruction-selection.md)).
- `define-instruction` clauses (macro at `s/cpnanopass.ss:10013`, see [instruction-selection.md](instruction-selection.md)) map each L15c `(set! live lhs rhs)` onto `(asm ,info ,asmop ,opnd …)` terms. The clause's pattern `(z ur) (x ur) (y ur) (u ur) (v ur)` is matched against actual operand shapes; the first matching clause wins, which is why **memory clauses are listed before register clauses** in the select family (contract cards below).
- Shared per-family helpers sit in `(definitions …)`: for the select family, `setcc-cc` (`s/x86_64.ss:405` for isel, `:528` for fpsel) and `invert-cc-select` (`:521`). Both exist so the emitter always receives "the condition for selecting strue", whatever arm order the source branch had — the clause absorbs the arm-order variation, the emitter sees a normalized contract.

## Section 3: the assembler (`s/x86_64.ss:1166` on)

`module asm-module` (`:1166-1175`) exports the emitters instruction selection calls (`asm-isel-regs … asm-fpsel-bool`, :1172-1173) plus `emit`, `asm-size`, `asm-jump`, `asm-return-address`, and friends. Full mechanics — `define-op`, byte encoders, `emit-code`, `emit-literal-code`, `asm-size` — are in [define-op-and-encoding.md](define-op-and-encoding.md). The one fact needed here: an emitter is a function

```
(code* dest self operand …) → code*
```

that prepends byte items `(byte . n)` / `(word . n)` / `(long . n)` / `(quad . n)` and `(asm ,op ,opnd …)` trace items onto `code*`, which is a reversed instruction stream ultimately consumed by `np-generate-code` ([code-generation-and-relocation.md](code-generation-and-relocation.md)).

## Contract cards: the select family

The select family is the knowledge base's worked example of a layer-1 contract (see `../README.md` and the case study `../05-case-studies/select-nan-reverse-bool.md`). There are six emitters — `asm-isel-regs`, `asm-isel-imms`, `asm-isel-bool` (`:2423`, `:2472`, `:2485`) for fixnum compares and `asm-fpsel-regs`, `asm-fpsel-imms`, `asm-fpsel-bool` (`:2511`, `:2539`, `:2552`) for flonum compares — and the clauses that feed them at `:379-499` (isel) and `:502-615` (fpsel). Note the family has only four members since `%fpsel=` was dropped (commit `d60a8ab1`).

### Card: `asm-isel-regs` (fixnum select, register arms)

| Field | Content |
|---|---|
| Producers | The `isel` clause `[(op (z ur) (x ur) (y ur) (u ur) (v ur))]` (`s/x86_64.ss:490-499`); reachable only when `setcc-instruction` is `#t` and `pred->isel` (`s/cpnanopass.ss:3746`) mapped the compare pred to `%isel<…%iselu<`, via the `select-if`/`select-tail` conversion in `np-normalize-context`. |
| Reachable shapes | z, x, y, u, v each a register or frame var of fixnum type; allocator may coalesce any pair of {dest, u, v} and may alias dest with x or y. The one unsafe case — **dest is the then-value** — is declined by the caller, handled by dispatching on the inverted condition instead. |
| Invariants | (1) `cmp` is emitted before any write, so dest aliasing x or y only affects the preset (R-4, `flags-truth-tables.md`). (2) All aliasing between dest and {u, v} is handled at emit time by dispatching on `(equal? dest u)` / `(equal? dest v)` — never a single preset sequence (RULE-ALIAS). (3) Condition codes are the T-1 low nibbles: `#x0C` l, `#x0E` le, `#x04` e, `#x0F` g, `#x0D` ge, `#x02` b (`iselu<`). No unordered column exists — integer compare is total (T-1), so no escape instruction is ever needed or allowed. |
| Derived from | T-1 + R-1/R-2/R-4 of [`flags-truth-tables.md`](flags-truth-tables.md); emitter comment at `s/x86_64.ss:2424-2439`. |

### Card: `asm-isel-bool` (fixnum select, boolean immediates)

| Field | Content |
|---|---|
| Producers | The `[(op (z ur) (x ur) (y ur) (u imm) (v imm))]` clause (`s/x86_64.ss:460-487`), reached only when both immediates are exactly `strue`/`sfalse` (checked with `constant strue`/`sfalse` at :463-469). |
| Reachable shapes | z register; x, y fixnum operands; cc already inverted by `setcc-cc` (`:405`) when the then-immediate is `#f`, so the emitter always sees the setcc condition *for selecting strue*. |
| Invariants | (1) `materialize(b) = (b << 3) + 6` maps the flag bit to `sfalse(6)`/`strue(14)`; the `b` driving it must be the "comparison true" bit for the arm order actually compiled (R-1/R-2). (2) **No `jp`, unconditionally**: integer flags have no unordered row (T-1). Emitting an escape "just in case" would violate RULE-TRUTH-NA's "say so rather than emitting one". (3) `cmp` reads x and y before anything writes dest; aliasing is safe (R-4). (4) The `setcc` byte sequence is synthesized by hand (REX computed from `ax-ea-reg-code`) and pushed with an `(asm isel-bool ,cc ,dest)` trace item via `aop-cons*`. |
| Derived from | T-1 + the boolean-materialization identity in `flags-truth-tables.md`; case study `../05-case-studies/select-nan-reverse-bool.md`. |

### Card: `asm-fpsel-regs` (flonum select, register arms)

| Field | Content |
|---|---|
| Producers | `fpsel` clause `[(op (z ur) (x fpur) (y fpur) (u ur) (v ur))]` (`s/x86_64.ss:609`); reachable only for `%fp<`/`%fp<=` — `pred->fpsel` (`s/cpnanopass.ss:3770`) maps only those two; `%fpsel=` was dropped from the family entirely (commit `d60a8ab1`) because its unordered escape was never made robust. |
| Reachable shapes | Same aliasing degrees of freedom as `asm-isel-regs`: dest may equal u, v, x, or y after coalescing. Equality (`cc = #x04`) additionally reaches this emitter in principle — the emitter still carries the `jp` path for it (`:2518-2529`), but no producer currently generates it. |
| Invariants | (1) `ucomisd` reads x and y before any write; dest aliasing is safe by R-4. (2) Aliasing dispatch on `(equal? dest u)` / `(equal? dest v)` mirrors `asm-isel-regs`, with the extra equality case using a `jp` whose skip length is computed from the emitted `mov` length (`movlen` at :2520-2521) — not a hand count (RULE-TRUTH-NA). (3) Conditions are the T-2 rows with the reversed operand read: `fpsel< → cmova (#x07)`, `fpsel<= → cmovae (#x03)`, `fpsel> → cmovb (#x02)`, `fpsel>= → cmovbe (#x06)`; on unordered, CF=ZF=PF=1 makes `a/ae/b/be` yield the else bit in **both** arm orders — no escape (T-2 ⚠ column excepted). |
| Derived from | T-2 + R-1/R-2/R-4 of [`flags-truth-tables.md`](flags-truth-tables.md); open thread on enabling equality selects in the case study. |

### Card: `asm-fpsel-bool` (flonum select, boolean immediates)

| Field | Content |
|---|---|
| Producers | `[(op (z ur) (x fpur) (y fpur) (u imm) (v imm))]` clause (`s/x86_64.ss:588-610`), same `strue`/`sfalse` guard as the fixnum bool clause. |
| Reachable shapes | z register; x, y FP operands; cc from `setcc-cc` (`:528`), i.e. `seta/setae/setb/setbe` for `<,<=,>,>=` (and `sete/setne` reserved for the not-yet-enabled equality form). |
| Invariants | (1) The `jp` is emitted **only when `cc = #x04`** (`:2573-2575`): equality is the single T-2 row whose unordered cell (ZF=1) inverts the ordered meaning, so only there does unordered need an explicit escape, and only the forward arm order is currently safe (RULE-TRUTH-NA; see the case study). For `a/ae/b/be` the flags already produce the else bit on unordered in either arm order — R-2's arm-swap symmetry holds for these rows and not for `e/ne`. (2) The materialization identity is the same `(b<<3)+6`; the `b` is "select strue" for the arm order actually compiled (R-1). (3) `ucomisd` reads x and y before any write to dest (R-4). (4) Skip offsets are computed from `(length setcc-bytes)` (:2574), never hand-counted. |
| Derived from | T-2 ⚠ row + R-1/R-2 of `flags-truth-tables.md`; fixed in commit `dd3eed46`, mats in `a8e3eb6d` — full post-mortem in `../05-case-studies/select-nan-reverse-bool.md`. |

### Card: `asm-isel-imms` / `asm-fpsel-imms` (immediate arms)

| Field | Content |
|---|---|
| Producers | The `(z mem)` clauses (`s/x86_64.ss:423-445`, `:546-566`) for memory destinations and the non-boolean `(u imm)(v imm)` fallback (`:470-487`, `:592-610`). |
| Reachable shapes | then-value pre-bound to a scratch `u` by the clause via a plain `set!`; dest may be memory. |
| Invariants | (1) The clause presets the scratch **with a plain `set!` before the self-referential `asm`** — the unspillable-conflict walk requirement behind RULE-UNSPILL (commit `5b6227fb`, "x86_64: preset the select temp for memory destinations"; see [instruction-selection.md](instruction-selection.md)). (2) Memory clauses are listed **before** the `ur` clauses so the `ur` predicate never sees a memory destination and routes it through an instruction-selection temporary whose self-referential asm would trip that walk — this ordering is itself part of the contract. (3) FP emitters never receive the equality condition — `%fpsel=` was dropped from the family (commit `d60a8ab1`) — so no `jp` is emitted anywhere in the family. |
| Derived from | RULE-UNSPILL in `../04-verification/review-checklists.md`; the `(z mem)` clause comments at `s/x86_64.ss:416-422` and `:538-545`. |

## Verifying a change here

Any change to these emitters or clauses is reviewed against checklist section A of `../04-verification/review-checklists.md` (RULE-TRUTH, RULE-SYM, RULE-TRUTH-NA, RULE-PRODUCERS, RULE-ALIAS, RULE-UNSPILL), with path evidence per `../04-verification/reachability-rule.md` and the executable cross-check in `../tools/verify-select-semantics.ss`.
