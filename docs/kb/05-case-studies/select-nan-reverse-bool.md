# Case Study: The Reverse-Order `asm-fpsel-bool` NaN Bug

The reference incident for the whole verification layer of this knowledge base. Fixed in commits `dd3eed46` (emitter) and `a8e3eb6d` (mats) on `x86-64-select`.

## Symptom

```scheme
(parameterize ([optimize-level 3]
               [run-cp0 (lambda (cp0 x) x)])
  (compile '(lambda (x y)
              (let ([r (if (fl< x y)
                           (#%$value (values #f))
                           (#%$value (values #t)))])
                r))))
;; applied to (+nan.0 2.0)  ⇒  #f    (correct answer: #t)
```

`(if (fl< x y) #f #t)` on NaN: `fl<` is false, so the else arm `#t` must be selected. The compiled code returned `#f`.

## The defect

The boolean specialization of the flonum select, `asm-fpsel-bool` (`s/x86_64.ss:2562`), emitted, unconditionally:

```
ucomisd x, y
mov     dest, 0
jp      skip            ; skip the setcc on unordered (PF=1)
setcc   dest.low        ; condition: "select strue"
skip:   shl dest, 3
        add dest, 6     ; 0→sfalse(6), 1→strue(14)
```

The `jp` pins unordered results at 0 = `#f`. The `define-instruction` clause inverts the setcc condition when the then-immediate is `#f` so that the emitter always receives "the condition for selecting strue" (`setcc-cc`, `s/x86_64.ss:528`). For the **forward** form (`then=#t, else=#f`) `#f` is indeed the else value on NaN — correct. For the **reverse** form (`then=#f, else=#t`) the else value is `#t`, and the `jp` still forces `#f`. The shortcut was derived for one arm order and silently generalized to both (violation of derivation rule R-2 in `../../03-backend/flags-truth-tables.md`).

## Truth-table resolution

`ucomisd` on unordered sets CF=ZF=PF=1. The relevant cells of T-2:

| condition | unordered |
|---|---|
| a (#x07) — forward `<` | 0 = else ✓ (no jp needed) |
| be (#x06) — reverse `<` (inverted) | **1 = else ✓** (no jp needed) |
| e (#x04) — equality | 1 ⚠ (misfires; jp needed, and only correct for the forward form) |

For `<`/`<=` the flags already produce the else bit in **both** arm orders. The `jp` was not merely misplaced — it was unnecessary, and harmful in the reverse order. Fix: emit the `jp` only for the equality condition (which `pred->fpsel` does not currently generate anyway; `s/cpnanopass.ss:3769` excludes `fp=` because its `cmov` fires on unordered ZF=1 and the compensating skip proved fragile). The equality special-casing was later removed with the family member itself — see the open-thread resolution below.

## Why every surface test stayed green (masked reachability)

`expand/optimize` was the first suspect and turned out to be innocent: `(expand/optimize '(lambda (x y) (if (fl< x y) #f #t)))` keeps the if with its `#f`/`#t` arms verbatim. The masks live in the nanopass mid-end, established by a `$np-tracer` battery (12 source shapes × o=2/o=3; see `../02-mid-end/cp0-shape-eating.md` for the full inventory):

1. **Pred-value boolean wrapper** (`np-optimize-pred-in-value`, `s/cpnanopass.ss:3302`, L9.75 — *before* `np-normalize-context`). Predicates reaching value position are re-wrapped in the forward boolean form, so user-written reverse orders in tail or value position never reach the select conversion as written.
2. **Fixnum-only swap gate** (`lift-seq-pred`, :3853): the `(if (inline pred) (false) (true))` swap form — the one place an arm swap is deliberately undone — is enabled only for `pred->isel` (:3864); there is no fpsel counterpart.
3. **Operand acceptance asymmetry**: `select-tail` accepts only bare immediates (:3883-3885), so opaque-arm reverse shapes in tail position do not convert either.
4. **Safe-op wrapping.** Untyped `fl<` expands (cpprim, `s/cpprim.ss`) into nested `flonum?` checks around `%fp<`; the select conversion only matches a bare comparison pred, so untyped code never reaches `fpsel` at all. Reaching it requires known-flonum operands (recipe S-4).

Positive control from the same trace battery: the S-1+S-2 recipe (opaque arms + cp0 bypass, effect position, o=3) is the *only* natural source shape that produces `%fpsel< '6 '14` — the reverse select — exactly the shape that reaches the buggy emitter.

The value probes accompanying the original setcc commit — "both arm orders, including NaN" — all passed, because in every probed shape the buggy sequence was never executed. Green mats, dead path, live bug.

## Forced-shape reproduction

Recipes S-1 + S-2 (`../../04-verification/shape-forcing-recipes.md`): the `#%$value` opaque arms survive the pred-value boolean wrapper intact, and the `run-cp0` bypass removes what remains of mid-end rewriting. With that, the reverse shape reaches `select-if` in effect position, the `(u imm)(v imm)` clause matches with `(u sfalse, v strue)`, `asm-fpsel-bool` receives the inverted condition, and NaN returns `#f`. (The same recipe in tail position does *not* convert — `select-tail` accepts only bare immediates — which is why the mat and this study use the let-bound, effect-position form.)

## Fix

- `s/x86_64.ss` — emit the `jp` only when the condition is equality (`cc = #x04`); comments now state the R-2 reasoning and the remaining constraint on any future equality-select enablement.
- `mats/fx.ms` — both arm orders with NaN, compiled under the S-1+S-2 recipe so the mat fails without the fix (the adversarial-shape-first rule, checklist item D).

Verified after the fix: the reproducer returns `#t`; fx and fl mats pass at o=0 and o=3; all natural shapes (tail/effect context, `not` combinations, o=0/2/3) unchanged.

## What this incident distilled into

| Artifact | Entry |
|---|---|
| Reachability rule (masked reachability named), and the full devourer inventory | `../../04-verification/reachability-rule.md`, `../../02-mid-end/cp0-shape-eating.md` |
| Shape-forcing recipes S-1/S-2 (S-3/S-4 from the same investigation) | `../../04-verification/shape-forcing-recipes.md` |
| Rules RULE-TRUTH-NA, RULE-SYM, RULE-DIFF, rule D (adversarial mat first) | `../../04-verification/review-checklists.md` |
| Derivation rules R-1…R-4 and the T-2 unordered column | `../../03-backend/flags-truth-tables.md` |
| Executable cross-checker | `../../tools/verify-select-semantics.ss` |

## Open thread — resolved by removal

`fp=` equality selects remain excluded from `pred->fpsel`, but the
hazardous machinery is gone: commit `d60a8ab1` dropped `%fpsel=` from
the instruction family and from `np-languages` entirely. The
replacement path, if equality selects are ever wanted: the skip must
be **computed from the emitted code** (not a length guess) and the
setcc boolean materialization cannot serve equality in both arm
orders at all (unordered ZF=1 aliases ordered-equal — no single
setcc/jp placement works), so a reintroduction needs a different
boolean sequence or the cmov forms only. Start from checklist
RULE-TRUTH-NA.
