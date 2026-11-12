# Shape-Forcing Recipes

Standard techniques for making a test (or a reproduction) present a *chosen* IR shape to a chosen pass, defeating the mid-end normalizations that would otherwise rewrite it. Each recipe names the normalization it defeats and the risk of using it.

All recipes below were exercised on the ta6le build; paths are relative to the repository root.

## Recipe S-1: opaque arms (`#%$value`)

**Defeats:** cp0 source-level rewriting of branch arms (boolean canonicalization, constant folding of arm values).

```scheme
;; instead of:            (if (fl< x y) #f #t)
;; use:
(if (fl< x y)
    (#%$value (values #f))
    (#%$value (values #t)))
```

cp0 does not see through `#%$value`, so the arm *order and identity* survives to `np-normalize-context` (`s/cpnanopass.ss:3740`), where `select-if`/`select-tail` convert the if into a `%fpsel<` with `(then, else)` in the written order. This is the recipe that exposed the reverse-order `asm-fpsel-bool` NaN bug (`../05-case-studies/select-nan-reverse-bool.md`).

## Recipe S-2: cp0 bypass

**Defeats:** all of cp0 (constant folding, inlining, boolean canonicalization, type-driven transformation).

```scheme
(parameterize ([optimize-level 3]
               [run-cp0 (lambda (cp0 x) x)])   ; cp0 never runs
  (compile '(lambda (x y)
              (let ([r (if (fl< x y)
                           (#%$value (values #f))
                           (#%$value (values #t)))])
                r))))
```

The compiled procedure can then be applied to adversarial inputs (NaN, infinities, boundary values) at runtime.

*Caution:* this tests the backend against IR a normal compile would never produce. A failure here is still a backend bug (the backend must honor IR semantics for any well-formed input), but a pass here does not excuse missing canonical-shape tests. Use S-1+S-2 together for the adversarial case, plain source for the canonical case.

## Recipe S-3: effectful test wrapper

**Defeats:** select conversion's predicate requirement (`lift-seq-pred` only unwraps a `seq` prefix ending in a *comparison* pred; an if whose test carries a genuine effect keeps its branchy shape — verified at `s/cpnanopass.ss:3853`).

```scheme
;; force a branchy reference implementation of the same predicate
(if (begin (vector-set! (make-vector 1) 0 1) (fl< x y))
    #t #f)
```

Useful as the **reference** side of a differential test: the wrapper guarantees the reference computes the predicate via the old, independent code path while the test subject uses the new one.

## Recipe S-4: type-laundering with `fl+`

**Defeats:** safe-operation wrapping. `(fl< (fl+ x 0.0) (fl+ y 0.0))` has known-flonum arguments, so `cpprim` inlines the *unsafe* `%fp<` directly in pred position — no type-check nest between the test and the comparison. (Without it, safe `fl<` expands to nested `flonum?` checks around the compare and the select conversion does not match; see `pred->fpsel` callers.)

## Choosing recipes

| You want to test… | Canonical shape | Adversarial shape |
|---|---|---|
| select conversion, forward order | plain source | S-1 |
| select conversion, reverse order | S-1 (+S-2 for runtime NaN injection) | S-1+S-2 |
| emitter specialization (e.g. setcc bool) | plain source + trace | S-1+S-2 + trace |
| NaN/boundary semantics | S-4 | S-1+S-2 |

[RULE-SHAPE] Every mat added for a backend specialization states in a comment which recipe forces the covered shape, or provides trace evidence instead (`./reachability-rule.md`).
