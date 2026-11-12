# x86-64 Flags Semantics: Authoritative Truth Tables

*Every specialization that consumes condition flags must be derivable from the tables on this page. If a sequence cannot be derived here, it is not allowed to land.* — see `[RULE-TRUTH]` in `../04-verification/review-checklists.md`.

Condition codes below are the low nibbles used by both `cmovcc` and `setcc` (`asmop-...` in `s/x86_64.ss`). Flag names: CF (carry), ZF (zero), SF (sign), OF (overflow), PF (parity, set on unordered by `ucomisd`).

## Table T-1: integer compare — `cmp x, y` computes x − y

| Condition | cc | x < y | x = y | x > y |
|---|---|---|---|---|
| e (equal) | #x04 | 0 | 1 | 0 |
| ne | #x05 | 1 | 0 | 1 |
| l (signed <) | #x0C | 1 | 0 | 0 |
| le | #x0E | 1 | 1 | 0 |
| g | #x0F | 0 | 0 | 1 |
| ge | #x0D | 0 | 1 | 0 |
| b (unsigned <) | #x02 | 1 | 0 | 0 |
| ae | #x03 | 0 | 1 | 0 |
| be | #x06 | 1 | 1 | 0 |
| a | #x07 | 0 | 0 | 1 |

Integer comparison is total: no unordered column exists, and no sequence built on `cmp` needs a NaN/unordered escape.

## Table T-2: FP unordered-compare — `ucomisd x, y` (flags from y vs x)

On ordered operands the flags reflect the y-vs-x comparison exactly as `cmp` would. On **unordered** operands (either operand NaN): **ZF = CF = PF = 1** (SF = OF = 0).

| Condition | cc | y > x (x < y) | y = x | y < x (x > y) | unordered |
|---|---|---|---|---|---|
| a  (CF=0 & ZF=0) | #x07 | 1 | 0 | 0 | **0** |
| ae (CF=0) | #x03 | 1 | 1 | 0 | **0** |
| e  (ZF=1) | #x04 | 0 | 1 | 0 | **1** ⚠ |
| ne (ZF=0) | #x05 | 1 | 0 | 1 | **0** ⚠ |
| b  (CF=1) | #x02 | 0 | 0 | 1 | **1** |
| be (CF=1 \| ZF=1) | #x06 | 0 | 1 | 1 | **1** |
| l  (sign≠of) | #x0C | — | — | — | reads SF/OF → 0 |
| le/ge/g | #x0E/#x0D/#x0F | — | — | — | reads SF/OF → 0/1/0 |

⚠ **The equality row is the single hazard in the whole table.** Every other condition yields, on unordered, exactly "the comparison is false" (a/ae → 0) or "the comparison is true" (b/be → 1) consistently with its ordered-false column. `e`/`ne` instead inherit ZF=1 from the unordered encoding and invert their ordered meaning. Any sequence using `e`/`ne` after `ucomisd` **must** have an explicit unordered escape (`jp`) whose skip target has been computed from the emitted code — a hand-counted skip offset is fragile under register coalescing (see `pred->fpsel` at `s/cpnanopass.ss:3769` and case study `../05-case-studies/select-nan-reverse-bool.md`).

## Derivation rules

**R-1 (NaN = else).** For a branchless select `z = cmp ? then : else`, unordered must produce the **else** value — that is exactly what the source branch `(if (cmp x y) then else)` does. Check the table row for the condition in *both* arm orders.

**R-2 (Arm-swap symmetry).** Reversing the arms (`then ↔ else`) replaces the condition with its boolean inverse (`invert-cc-select`, `s/x86_64.ss`). A shortcut valid for one order is valid for the other **only if the row's unordered cell is invariant under the swap** — i.e. only if the unordered cell already equals the else-value's bit for both orders. For `a/ae/b/be` this holds; for `e/ne` it does not.

**R-3 (No un-derived shortcuts).** Comments stating flag behavior (e.g. "the jp keeps NaN at #f") are claims about table cells and must name the condition(s) they apply to. A claim that silently generalizes from one arm order to both is exactly the bug class of the select NaN incident.

**R-4 (Operand read order).** `cmp`/`ucomisd` read both operands before any subsequent instruction writes the destination register, so a destination aliasing a compare operand is safe *provided nothing writes the destination between the compare and its consumption* — the register allocator may coalesce the destination with either select arm, which is why the `asm-*-regs` emitters dispatch on `(equal? dest u)` / `(equal? dest v)` instead of presetting unconditionally (`asm-fpsel-regs`, `s/x86_64.ss:2513`).

## The boolean materialization identity

Chez's fixnum boolean immediates are `sfalse = 6`, `strue = 14`:

```
materialize(b) = (b << 3) + 6        b ∈ {0,1}
```

This is *one instance* of the general constant-select identity `select(P, A, B) = B + (A−B)·b`. Specializing on the `strue/sfalse` pair is legitimate for code quality, but the specialization must still honor R-1/R-2: the `b` driving the identity must be the "comparison true" bit *for the arm order actually being compiled*. The `asm-fpsel-bool` fix (drop the unconditional `jp` entirely — no generated condition needs one) is the canonical application of R-2; the equality condition it once kept the `jp` for turned out to be unservable by the setcc form in both arm orders at all and was dropped from the family — see the case study.
