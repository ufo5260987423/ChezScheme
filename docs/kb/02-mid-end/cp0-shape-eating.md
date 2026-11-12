# cp0 and Mid-End Shape-Eating: How Normalization Masks Backend Reachability

The systematic account of **masked reachability** (named in `../04-verification/reachability-rule.md`): which mid-end normalization eats which backend-reachable shape, with the branchless-select work as the running example. Case study: `../05-case-studies/select-nan-reverse-bool.md`. All experiments below were run on the ta6le build at commit `a8e3eb6d`; commands are reproduced so every claim is re-checkable.

## Experiment setup

```sh
cd ta6le && bin/ta6le/scheme -q
```

```scheme
(import (chezscheme))
(pretty-print (expand/optimize '...))            ; cp0's view of the source
(#%$np-tracer 'np-normalize-context) (compile '...) (#%$np-tracer #f)
                                                 ; IR after a chosen pass
```

`(#%$np-tracer 'name)` uses the pass driver at `s/cpnanopass.ss:110-140`; it prints the unparsed IR after the named pass(es) to stderr. This is the "instrumented compiler run" option of the reachability rule, one notch lighter than an emitter probe.

## First, a correction: cp0 is not the eater

The select NaN case study attributes the mask to "cp0 shape-eating", and `expand/optimize` is quoted as showing "the normalized form". Verified directly:

```scheme
(expand/optimize '(lambda (x y) (if (fl< x y) #f #t)))
;; => (lambda (x y) (if (#2%fl< x y) #f #t))     -- if and #f/#t arms verbatim
(expand/optimize '(lambda (x y) (not (fl< x y))))
;; => same reverse if
```

cp0 *does* eat the **forward** form — `(if (fl< x y) #t #f)` reduces to the bare `(fl< x y)` — but the **reverse** shape survives cp0 completely, including the `not` expansion and the typed `(fl< (fl+ x 0.0) (fl+ y 0.0))` variant. The reverse-boolean-eating happens later, inside the nanopass mid-end. Locating it precisely matters: the masks to audit are the five below, not cp0's rewrite rules — and a test strategy that only exercises source-level shapes would miss every one of them.

## The eaters, in execution order

Driver order (`$np-compile`, `s/cpnanopass.ss:11146-11191`): `$np-expand-primitives` (:11180) → `np-optimize-pred-in-value` (:11184) → `np-remove-complex-opera*` (:11185) → `np-normalize-context` (:11187).

### Eater 1 — boolean-value wrapper (`np-optimize-pred-in-value`, :3302, L9.75)

A boolean-valued `if` — both arms boolean constants, in value context — is wrapped so the *result* is explicitly boolean (`s/cpnanopass.ss:3304-3308`, `:3324-3328`):

```scheme
(if e0 b1 b2)   ⇒   (if (if e0 b1 b2) strue sfalse)
```

The user's arm order survives only on the *inner* if; the new outer if is always forward (`strue`/`sfalse`, i.e. 14/6). Verified by tracing: after this pass, `(lambda (x y) (if (fl< x y) #f #t))` shows arms `6`/`14` (written order); after `np-normalize-context` the arms visible to any select matcher are `'14`/`'6` — forward.

### Eater 2 — test coercion (`np-normalize-context`, :3740)

`select-if` (`:3810-3841`) and `select-tail` (`:3874-3901`) only match an `if` whose **test is a bare `(inline pred-prim ...)`** (`:3814`, `:3878`) — or, via `lift-seq-pred` (`:3853`), a `seq` prefix ending in one. Everything else falls through to the generic clause and keeps its branch (`:4022`, `:4079`). A value test is coerced to a `Pred` by wrapping it in an `(if … (false) (true))`-shaped pred (observable in every trace below), which inserts a pred-level `if` between the user's arms and the select matcher. The user's reverse arms end up *inside* that coercion, on a pred — and preds have no select conversion at all.

### Eater 3 — safe-op check nest (`$np-expand-primitives`, `s/cpprim.ss`)

Untyped `fl<` at o≤2 expands to nested `%type-check?` conditionals around the `%fp<` (`build-bind-and-check`, `s/cpprim.ss:5225-5245`; see `primitive-expansion.md`). The compare is then the then-arm of an `if`, not a bare pred, so Eater 2 declines even when the arms would have matched. Traced shape (untyped, o=2):

```
(if (if (%type-check? x) (%type-check? y) #f) (%fp< x.flo y.flo)
    (begin (pariah) (libcall fl< x y)))   ;; ← test of the user's if
```

At o=3 the level-3 handler inlines `fl<` with no checks (`s/cpprim.ss:5211-5214`), so this mask disappears and Eater 1/2 are the whole story.

### Eater 4 — the seq-lift swap gate (`lift-seq-pred`, :3853)

`lift-seq-pred` unwraps `(if (seq e … (inline pred …)) t1 t2)` so the trailing comparison meets the select matcher, and it *can* swap arms for one shape — `(if (inline pred …) (false) (true))` — but the swap branch is gated on `pred->isel` only (`:3863-3869`, gate at `:3864`):

```scheme
[(if (inline ,info ,pred-prim ,t* ...) (false) (true))
 (if (pred->isel pred-prim)              ; fixnum only — no pred->fpsel
     (values (reverse pfx) `(inline ,info ,pred-prim ,t* ...) #t)
     (values #f #f #f))]
```

Consequence: even the compiler's own `(if (inline fp<…) (false) (true))` pred shape — which is exactly what a reverse-boolean would look like if it ever reached pred position intact — is never swapped onto an `fpsel`. There is no code path that produces a reverse-order flonum select from user source. (The fixnum side *does* swap; `%eq?` is in `pred->isel`, `:3755` — yet traces of call-in-test-position reverse booleans still show no `%isel=` select, because Eater 1's wrapper intercepts first.)

### Eater 5 — forward-only boolean materialization (`rhs-inline`, :3902)

A pred primitive used as a *value* (the common case after Eater 1) becomes a select via `rhs-inline`, which hardcodes the forward pair (`s/cpnanopass.ss:3913-3919`):

```scheme
`(seq (set! ,u (inline ,null-info ,sel ,t* ... ,(%constant strue) ,(%constant sfalse)))
      ,u)
```

`strue`/`sfalse` order is fixed in the template. This is the *only* select natural forward code gets at o≤2 (verified: untyped `(if (fl< x y) #t #f)` compiles to `%fpsel< … '14 '6` through this path, arms forward).

## The measured result

Battery compiled at o=2 (default) and o=3, tracing `np-normalize-context`; "select" = any `%fpsel<`/`%isel*` in the output with its immediate arm order:

| Source shape | o | select generated |
|---|---|---|
| `(if (fl< x y) #f #t)` tail / value, untyped | 2 | none |
| `(if (fl< x y) #t #f)` tail / value, untyped | 2 | forward `%fpsel< '14 '6` (via rhs-inline) |
| `(not (fl< x y))` | 2 | none |
| `(if (fl< (fl+ x 0.0) (fl+ y 0.0)) #f/#t)` tail | 2 | none / forward |
| `(if (fl> (fl+ x 0.0) (fl+ y 0.0)) #f/#t)` tail | 2 | none (`fl>` already swapped onto `%fp<`, `s/cpprim.ss:5221`) |
| `(if (fx< x y) #f #t)` / `#t #f` | 2 | none / forward `%isel<` |
| `(if (assq 'a l) #f #t)` (call in test) | 2 | none |
| S-1 opaque arms (`#%$value`), reverse, any typing | 2 | none (check-nest still present; arms end up on a pred-level coercion if) |
| S-1 opaque arms, forward | 2 | forward `%fpsel< '14 '6` — Eater 5 fires regardless of arm opacity |
| S-1+S-4 (opaque arms + `fl+` launder), reverse | 2 | none |
| **S-1+S-2 (opaque arms + `run-cp0` bypass), reverse, value context** | 3 | **reverse `%fpsel< … '6 '14`** |
| S-1+S-2, forward, value context | 3 | forward `%fpsel< … '14 '6` |

Positive control, exact case-study repro shape:

```scheme
(parameterize ([optimize-level 3] [run-cp0 (lambda (cp0 x) x)])
  (compile '(lambda (x y)
              (let ([r (if (fl< x y)
                           (#%$value (values #f))
                           (#%$value (values #t)))])
                r))))
;; tracer shows: (set! r (inline #<info> %fpsel< x.flo y.flo '6 '14)) — reverse
```

Two subtleties the traces exposed, both worth keeping:

- S-1+S-2 in *tail* position still produces no select: the arms arrive as `(values '6)`/`(values '14)` tails, and `select-tail` only accepts bare immediates or uvars (`:3883-3885`). The value context (via `let`) is what makes the immediates visible to `select-if`.
- S-1+S-4 at o=2 launders the `fl<` arguments but the `fl+` wrappers reintroduce `%type-check?` guards (their own arguments are untyped), so the select attaches to the guard's then-arm via `rhs-inline` — forward only. At o=3 the level-3 `fl+` handler has no checks, so S-1+S-4 *would* suffice there; S-2 is the stronger, level-independent recipe.

Runtime spot-checks all pass (`(1.0 2.0)⇒#f`, `(2.0 1.0)⇒#t`, `(1.0 1.0)⇒#t` at o=2 and o=3), confirming the masks hide a *path*, not a value-semantics difference — the compiled natural code is correct; it simply never executes the reverse-order emitter path.

## Shape-eating checklist

| Normalization | Where | Eaten shape | Defeated by |
|---|---|---|---|
| cp0 boolean canonicalization of arm *values* | `expand/optimize` | forward `(if p #t #f)` collapses to bare `p`; constant arms fold | S-1 (`#%$value` opaque arms) |
| Boolean-value wrapper | `np-optimize-pred-in-value` `s/cpnanopass.ss:3302` | arms detached from pred: `(if (if p b1 b2) strue sfalse)` — reverse order unreachable downstream | S-2 (`run-cp0` bypass); S-1 at o=3 |
| Test coercion to `Pred` | `np-normalize-context` `s/cpnanopass.ss:3740` | value tests wrapped in pred `if`; only bare `(inline pred …)` or liftable `seq` matches | S-2 |
| Safe-op check nest | `$np-expand-primitives` `s/cpprim.ss:5225` | bare `%fp<` pred under `%type-check?` ifs (o≤2) | S-4 (`fl+` laundering, o≤2); moot at o=3 |
| `seq`-lift swap gate | `lift-seq-pred` `s/cpnanopass.ss:3863-3869` | the one swap path is fixnum-only (`pred->isel`, `:3864`); no fp reverse select is constructible | not user-reachable; backend must still honor the IR shape (S-2 caution, `../04-verification/shape-forcing-recipes.md`) |
| Forward-only boolean materialization | `rhs-inline` `s/cpnanopass.ss:3902-3919` | boolean value of a pred is always a forward select | S-1+S-2 |

## Rules this implies

- A backend specialization's contract card must state which IR shapes reach it *after these five eaters*, not which source shapes produce it. "Any `(if (fl< ..) #f #t)`" is a false contract; "a same-destination `%fpsel<` with `(u sfalse)(v strue)`" is a true one.
- Per `RULE-REACH` (`../04-verification/reachability-rule.md`), a mat for such a specialization carries path evidence; per `RULE-SHAPE`, it names the recipe that forces the covered shape. The table above is the map from "recipe" to "which eater it defeats".
- Emitter reasoning follows `../03-backend/flags-truth-tables.md` (R-1/R-2 in particular): both arm orders are legal IR, so both must be derivable from the truth tables even when only one is reachable from natural source today.
