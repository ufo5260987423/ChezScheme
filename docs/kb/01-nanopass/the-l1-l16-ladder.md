# The L1–L16 Language Ladder

How to read `s/np-languages.ss`: 30 `define-language` forms (28 in the file, `L1` at `s/np-languages.ss:424` through `L16` at `:1310`, plus `Lsrc` in `s/base-lang.ss:219` and `Lexpand` in `s/expand-lang.ss:74`), each a small diff over the previous one. This article explains the increment mechanism, what each level disambiguates, and how to read a production diff between two levels. Pass line numbers are from this checkout (commit `a8e3eb6d`); the overview table in `../00-overview/compilation-pipeline.md` is the map, but verify anchors against your tree — several of its back-half numbers have drifted.

## The mechanism

```scheme
(define-language L6 (extends L5)
  (terminals (+ (maybe-var (mcp))))
  (entry CaseLambdaExpr)
  (Expr (e body)
    (- (letrec ([x le] ...) body))
    (+ (closures ([x* (x** ...) le*] ...) body)))
  (CaseLambdaClause (cl)
    (- (clause (x* ...) interface body))
    (+ (clause (x* ...) mcp interface body))))
```

(`s/np-languages.ss:545-555`.)

- `(extends L5)` copies the parent spec; only changes are listed.
- `(+ production)` adds, `(- production)` removes; terminals diff the same way with their meta-var lists.
- `=> form` on a production overrides its unparsed shape (what `unparse-L*` prints) — important when reading traces, since the printed form can differ from the internal shape.
- A level with no `(extends ...)` (e.g. `L13` at `s/np-languages.ss:1029`, `L15a` at `:1165`) is a ground-up rewrite; expect a big diff.
- Comments above each `define-language` state the intent — treat them as the level's contract (e.g. `L10` at `s/np-languages.ss:854-859`, `L11` at `:920-924`, `L13` at `:1025-1028`).

## Level map

Front half (`$np-compile`, `s/cpnanopass.ss:11146-11191`):

| Level | Line | Produced by | What it disambiguates |
|---|---|---|---|
| Lsrc | `base-lang.ss:219` | expander/cprep | core forms pre-nanopass |
| L1 | :424 | `cpnanopass` (:683) | canonical core: `call`, `if`, `seq`, `set!`, `letrec`, `case-lambda` |
| L2 | :462 | `np-recognize-let` (:752) | `let` introduced |
| L3 | :469 | `np-discover-names` (:786) | names recorded in info records |
| L4 | :476 | `np-convert-assignments` (:831) et al. | assigned-variable handling |
| L4.5 | :483 | `np-recognize-mrvs` (:955) | multiple-return-value call sites |
| L4.75 | :495 | `np-expand-foreign` (:1031), `np-recognize-loops` (:1076) | foreign stubs; loop recognition |
| L4.875 | :508 | `np-convert-loops` (:1135) | loops converted |
| L4.9375 | :523 | `np-recognize-attachment` (:1209) | attachments |
| L5 | :538 | `np-name-anonymous-lambda` (:1405) | every lambda named in its info |
| L6 | :545 | `np-convert-closures` (:1418) | `closures` form + per-clause `mcp` (maybe closure parent); see `../02-mid-end/closure-conversion.md` |
| L7 | :564 | `np-expand[-/optimize]-closures` (:2011/:2092) | top-level `labels` `Program`; `inline`, `label-ref`, lvalues/`mref`; `closures` gone |
| L9 | :823 | `$np-expand-primitives` (`s/cpprim.ss:106`) | no `quote`/`primref`; `hand-coded`; see `../02-mid-end/primitive-expansion.md` |
| L9.5 | :838 | `np-place-overflow-and-trap` (:3027) | `trap-check`/`overflow-check` placement |
| L9.75 | :848 | `np-finalize-loops` (:3288) | `loop` form removed |
| L10 | :860 | `np-remove-complex-opera*` (:3330) | bindings → locals + `set!`; value split into `Triv`/`Rhs`/`Expr` |
| L10.5 | :907 | `np-push-mrvs` (:3567) | `mvset`/`mlabel` forms |
| L11 | :925 | `np-normalize-context` (:3740) | **expressions normalized into `Tail`/`Pred`/`Effect` context**; `primitive` split into value/pred/effect |
| L12 | :989 | `np-flatten-case-lambda` (:4133) | `entry-point` per clause; `do-rest`; mvset ebody |
| L12.5 | :1013 | `np-insert-trap-check` (:4265) | `trap-check` gone from `Effect` |
| L13 | :1029 | `np-impose-calling-conventions` (:4282) | conventions imposed: no call args, no clause formals; `new-frame`, `return-point`, `fv`; see `../02-mid-end/calling-conventions.md` |

Back half (`np-after-calling-conventions`, `s/cpnanopass.ss:11122-11144`):

| Level | Line | Produced by | What it disambiguates |
|---|---|---|---|
| L13.5 | :1104 | `np-expand-hand-coded` (:5977) | hand-coded entry/runtime routines expanded |
| L14 | :1112 | `np-expose-allocation-pointer` (:7038) | `alloc` gone (allocation pointer explicit) |
| L15a | :1165 | `np-expose-basic-blocks` (:7253) | **block graph**: `(lambda info max-fv (local* ...) (entry-block* ...) (block* ...))`; see `../02-mid-end/basic-blocks.md` |
| L15b | :1221 | (inside register allocation) | frame-relative ops (`fp-offset`) replace `fv`/`remove-frame` shapes |
| L15c | :1255 | (live analysis) | operands are `ur` (reg/uvar); `mref` of lvalues |
| L15d | :1267 | `select-instructions!` (:10203) | **`inline`/`pred`/`effect` → `(asm ,proc ,opnd ...)`** — instruction selection input→output |
| L15e | :1296 | (frame assignment) | `uvar` → `reg` only; locals list gone |
| L16 | :1310 | `np-allocate-registers` (:10886) | `overflow-check` with handler resolved; final pre-codegen shape |

## Reading a production diff: L10.5 → L11

This is the level where the branchless-select conversion lives, so it is the diff that matters for `../02-mid-end/cp0-shape-eating.md`.

`L10.5` (`s/np-languages.ss:907-918`) has one undifferentiated `Expr` with `call`, `if`, `seq`, `set!`, `mvset`, `values`, `goto`, `mlabel`, inline forms, checks — anything can appear anywhere.

`L11` (`:925-987`) is the first level with *contexts*. Read the diff in three steps:

1. **Terminal split** (`:927-931`): the single `(primitive (prim))` terminal is replaced by `value-primitive`, `pred-primitive`, and `effect-primitive`. After this pass the *same operator* is three different terminals depending on the context it appears in — that is what lets `np-normalize-context` pattern-match "a bare comparison in predicate position" precisely (the shape `select-if`/`select-tail` require; `s/cpnanopass.ss:3810`/`:3874`).
2. **`Expr` shrinks** (`:939-954`): `if`, bare `seq`, `values`, `goto`, `mlabel`, and most statement-ish forms are removed from `Expr`. Whatever is left must be expressible as an effect sequence ending in a tail.
3. **`Tail`/`Pred`/`Effect` are introduced** (`:955-987`):
   - `Tail` gets `if`, `seq`, `values`, `goto`, `rhs` — a clause body is a `Tail`.
   - `Pred` gets `(true)`/`(false)`, `if`, `seq`, `goto`, `mlabel`, and crucially `(inline info pred-prim t* ...)` — a *bare comparison pred*.
   - `Effect` gets `nop`, `set!`, `if`, `seq`, checks, `profile`, `mvset`, `foreign-call`, `(tail tl)` — statements only.

The head comment (`:920-924`) states the contract: *"expressions are normalized into Tail, Pred, or Effect context"*. The select conversion then matches, in `Effect`/`Tail` context, an `if` whose test is a bare `(inline pred-prim ...)` and whose arms assign the same destination; anything else keeps its conditional branch. Which user-level shapes survive to that point is exactly what `../02-mid-end/cp0-shape-eating.md` measures.

## Tips

- Trace, don't guess: `(#%$np-tracer 'np-normalize-context)` then `compile` prints the unparsed IR after the pass (see `define-language-and-define-pass.md`).
- When a trace surprises you, diff the *languages*, not the pass code: the production list tells you what shapes the pass could possibly emit.
- Fractional levels (L4.5…L9.75) exist so that each pass has a distinct input/output contract even when the delta is three productions.
