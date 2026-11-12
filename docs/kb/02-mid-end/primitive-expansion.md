# Primitive Expansion (`$np-expand-primitives`)

How source-level primitives become IR: the safe/unsafe split, the type-check nest, and the `fl>`→`fp<` swap — including why the result is invisible to the backend's select conversion unless the operands are provably flonums. This is the second mask in the select NaN incident; the recipes that defeat it are S-4 (and S-2) in `../04-verification/shape-forcing-recipes.md`.

## Location and wiring

- The pass lives in `s/cpprim.ss` (file header, `:1-3`: used only by `cpnanopass.ss`, split out to reduce compilation-unit size).
- `np-expand-primitives` defined at `s/cpprim.ss:106`, L7 → L9; exported to the driver by `(set! $np-expand-primitives np-expand-primitives)` at `:8728`; called from `$np-compile` at `s/cpnanopass.ss:11180`.
- Both files are listed together in `compiler-names` (`s/build.zuo:118`) and share the includes from `cpnanopass-src-names` (`s/build.zuo:126`); `cpprim.ss` itself includes `np-languages.ss`, `np-register.ss`, `np-info.ss`, `np-help.ss` (`s/cpprim.ss:11-16`).
- Handlers are registered per optimize level in two hashtables, `ht2` and `ht3` (`s/cpprim.ss:54-60`): a level-3 handler wins at o=3, else the level-2 handler runs.

## The safe/unsafe split

A *safe* primitive (`fl<`) must signal an error on non-flonum arguments. An *unsafe* primitive (`%fp<`) assumes flonums and emits the raw operation. `$np-expand-primitives` turns the safe form into IR that checks, then jumps to the unsafe inline on the provably-flonum path, falling back to a library call (which raises) on the slow path.

Flonum comparisons are built by `define-fl-cmp-inline` (`s/cpprim.ss:5201-5223` at o=3, `:5273-5307` at o=2), registered (`:5219-5223`, `:5303-5307`) as:

```scheme
(define-fl-cmp-inline fl<  fl<?  build-fl<  #t #f)
(define-fl-cmp-inline fl>  fl>?  build-fl<  #t #t)   ; swapped!
(define-fl-cmp-inline fl<= fl<=? build-fl<= #t #f)
(define-fl-cmp-inline fl>= fl>=? build-fl<= #t #t)   ; swapped!
```

`build-fl<`/`build-fl<=` (`:5191`, `:5199`) emit `` `(inline ,(make-info-unboxed-args '(#t #t)) ,%fp< ,e1 ,e2) `` — the unsafe compare. The `swapped?` flag (`:5205-5206`) reverses the arguments, so **`fl>`/`fl>=` are compiled as `%fp<`/`%fp<=` on swapped operands**. Downstream only `fp<` and `fp<=` exist as fp comparison predicates — `pred->fpsel` relies on exactly this (`s/cpnanopass.ss:3762-3764`).

### o=2: the check nest

`build-bind-and-check` (`s/cpprim.ss:5225-5245`) wraps the inline:

```scheme
(if (known-flonum-result? e1)
    (if (known-flonum-result? e2)
        body                              ; bare %fp< inline
        (bind ... `(if ,(%type-check mask-flonum type-flonum ,e2)
                      ,body ,(build-libcall ...))))
    ...)
```

`known-flonum-result?` (`:20-38`) recognizes uvars typed `'fp`, flonum quotes, calls with `*result-type* flonum`, fp foreign calls, and seq/let/if compositions thereof. When both arguments check out, the unsafe compare is emitted **bare**; otherwise the compare sits under nested `%type-check?` conditionals with a pariah libcall fallback.

Verified on the ta6le build (tracer on `np-optimize-pred-in-value`, compiling `(lambda (x y) (if (fl< x y) #f #t))` at o=2): the `fl<` value arrives as

```
(if (if (%type-check? x 7 2) (%type-check? y 7 2) 6) 14 6)
    (inline %fp< (mref x zero 6 fp) (mref y zero 6 fp))
    (begin (pariah) (call libspec fl< x y)))
```

i.e. exactly the nest described above — the `%fp<` is the then-arm of an `if`, not a bare pred.

### o=3: no checks at all

The level-3 registration has no `build-bind-and-check` (`:5210-5214`): `(fl< e1 e2)` inlines directly to `%fp<`. Type safety at o=3 is delegated to cp0/cptypes, which either prove the arguments' types or insert their own guards elsewhere. Consequence for verification: the check-nest mask below is an o≤2 phenomenon; at o=3 the bare pred appears naturally, and the remaining masks are the boolean wrapper and test coercion (see `cp0-shape-eating.md`).

## Why the nest defeats select conversion

The branchless-select conversion in `np-normalize-context` (`s/cpnanopass.ss:3740`) matches only:

- `select-if`/`select-tail`: an `if` whose **test is a bare `(inline pred-prim ...)`** (`:3814`, `:3878`) with select operands as arms, or
- a `seq` prefix ending in such a pred, lifted by `lift-seq-pred` (`:3853-3861`).

The check nest satisfies neither: the `%fp<` is buried as the then-arm of a type-check `if`, so the user's `if` keeps its conditional branch. Even the o=2 *forward* form only becomes a select because the boolean *value* of the whole nest is converted separately, by `rhs-inline` (`:3902-3919`), once the nest collapses to a known boolean.

**Recipe S-4** (`../04-verification/shape-forcing-recipes.md`) launders the operands: `(fl< (fl+ x 0.0) (fl+ y 0.0))` has `known-flonum-result?` arguments, so the o=2 expansion emits the bare `%fp<` inline and the select conversion can match. Trade-off observed while verifying: the `fl+` wrappers carry their own `%type-check?` guards when `x`/`y` are untyped, so the select applies to the then-arm of the guard `if`, not to the user's `if` — S-4 reaches `fpsel`, but only via the boolean-value path, with the arm order the compiler chose (always forward; see `cp0-shape-eating.md`).

## Related expansion facts

- After this pass, `quote`/`primref` are gone and `hand-coded` exists (L9, `s/np-languages.ss:823-835`).
- "Expressions producing double values always flow to an `inline` expecting doubles; such results must be put in a `'fp` temporary" (comment `s/cpprim.ss:42-46`) — the contract `np-unbox-fp-vars!` (`s/cpnanopass.ss:2852`) enforces.
- Multi-argument comparisons reduce via `reduce-fp-compare` (`:5207-5214`) rather than nesting pairwise checks.
