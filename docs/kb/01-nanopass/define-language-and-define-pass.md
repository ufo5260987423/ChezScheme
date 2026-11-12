# `define-language` and `define-pass`: The Nanopass Framework

What the nanopass framework (git submodule `nanopass/nanopass/`) actually does, and how the Chez compiler drives it. Read `../00-overview/compilation-pipeline.md` first for where this fits.

## The pieces

The framework is a set of small libraries; the ones that matter for reading Chez:

| File (under `nanopass/nanopass/`) | Library | Role |
|---|---|---|
| `language.ss` (536 lines) | `(nanopass language)` | `define-language` macro (`language.ss:26`, expansion driver `x-define-language` at `:34`); also exports `language->s-expression`, `diff-languages`, `prune-language`, `define-pruned-language` (`:18`) |
| `records.ss` (804 lines) | `(nanopass records)` | Record layer for language descriptions: `language`, `tspec` (terminal spec), `ntspec` (nonterminal spec), and the alternative (`alt`) records; name↔spec lookups (`find-spec`, `id->spec`, …) |
| `parser.ss` | `(nanopass parser)` | `define-parser` — turns an input s-expression into the record representation of a language |
| `unparser.ss` | `(nanopass unparser)` | `define-unparser` — turns records back into s-expressions (this is what `unparse-L15a` etc. are) |
| `pass.ss` (1628 lines) | `(nanopass pass)` | `define-pass` (`pass.ss:201`, driver `x-define-pass` at `:240`), `with-output-language` (`:94`), `trace-define-pass`, `echo-define-pass` (`:17`) |
| `nano-syntax-dispatch.ss` | `(nanopass nano-syntax-dispatch)` | The pattern-matching dispatcher behind pass clauses (`nano-syntax-dispatch`, `:14`); pattern keywords `any`/`each`/`each+`/`each-any` |
| `helpers.ss` | `(nanopass helpers)` | Auxiliary keywords (`extends`, `definitions`, `entry`, `terminals`, `nongenerative-id`, `maybe`) shared by language and pass definitions |

## `define-language`

A language declaration has three parts:

1. **`(terminals (type (meta-var ...) [handler]) ...)`** — the leaf types. Each terminal type supplies a predicate; the meta-vars are the pattern variables used in productions and pass clauses.
2. **`(Nonterminal (meta ...) production ...)`** — the productions. Each production `(head field ...)` becomes a record type with predicate `head?` and accessors `head-field`; the optional `=>` form gives the *pretty/unparse* shape (e.g. `(call info e0 e1 ...) => (e0 e1 ...)` at `s/np-languages.ss:440`).
3. **`(entry Nonterminal)`** and **`(extends L)`** — the start symbol, and the incremental-diff mechanism: `(+ ...)` adds productions/terminals, `(- ...)` removes them. `x-define-language` merges the parent's spec into the child's (`tspec=?`/`ntspec=?`/`alt=?` equality at `language.ss:41-61`), so an extension only states what changed.

`define-language` generates: the nonterminal record types, a parser, a meta-parser (used by `with-output-language` to check quoted output templates), and an unparser (`unparse-L*`).

## `define-pass`

Clause shape, as used throughout `s/cpnanopass.ss`:

```scheme
(define-pass np-normalize-context : L10.5 (ir) -> L11 ()
  (definitions ...)
  (Effect : Expr (ir) -> Effect ()
    [(if ,[Pred : e0] ,[e1] ,[e2]) ...]))
```

- **Automatic descent (catamorphism).** Each clause names an input nonterminal and an output nonterminal; subscripted pattern variables `,[e]` (or `,[Nonterminal : e]`) recursively invoke the matching processor and bind the result. Productions with no clause fall through to a generated clause that copies the node and recurses — the pass author writes only the cases that change.
- **Per-production dispatch.** The clause left-hand side is a language pattern: `[(if ,[Pred : e0] ,[e1] ,[e2]) ...]` matches the `if` production of the input `Expr` (`s/cpnanopass.ss:4018`); `guard` expressions restrict the match (e.g. `s/cpnanopass.ss:4083`).
- **Explicit arguments and multiple return values.** Processors take extra arguments — `(ir index clinfo)` in `np-convert-closures` (`s/cpnanopass.ss:1449`) — and can return more than one value with `-> * (block block*)`, as in the nested pass `build-graph` (`s/cpnanopass.ss:7273`), or `-> * (code)` in `np-generate-code` (`s/cpnanopass.ss:8437`).
- **`with-output-language`** (`pass.ss:94`) is the quasiquote form for building output: `(with-output-language (L11 Effect) `(set! ,x (inline ,null-info ,sel ,t* ... ,a1 ,a2))`)` (`s/cpnanopass.ss:3840`). The template is run through the output language's meta-parser at expansion time, so malformed output is a syntax error, not a late crash.
- **`(definitions ...)`** holds pass-local helpers; `pass-options` (`echo`) control tracing.

## How Chez uses it

- `s/compile.ss:19` — `(import (nanopass))`; `s/np-languages.ss:85` does the same and `include`s `base-lang.ss`, which defines `Lsrc` (`s/base-lang.ss:219`); `Lexpand` lives in `s/expand-lang.ss:74`.
- `s/np-languages.ss` defines 28 languages `L1`…`L16` (fractional levels included, no `L8`) — see `the-l1-l16-ladder.md`.
- `s/cpnanopass.ss` contains 58 `define-pass` forms, `s/cpprim.ss` one (`np-expand-primitives`, `s/cpprim.ss:106`). The driver is `$np-compile` (`s/cpnanopass.ss:11146`), which composes the front half and hands off to `np-after-calling-conventions` (`:11122`) for the back half.
- Supporting files collected by the build (see below): `s/np-info.ss` (the `info` record family, e.g. `info-lambda` with its mutable interface*/dcl*/fv*/well-known? fields), `s/np-help.ss` (`%`-prefixed expression-construction macros), `s/np-register.ss` (the `architecture` macro that splices the machine file, `:1`, and `define-registers`, `:104`).
- Build wiring: `s/build.zuo` lists the compiler sources in `compiler-names` (`s/build.zuo:118` — `cpnanopass.ss`, `cpprim.ss`, `compile.ss`, `cback.ss`) and the included helpers in `cpnanopass-src-names` (`s/build.zuo:126` — the per-arch `<arch>.ss` files, `np-languages.ss`, `np-register.ss`, `np-info.ss`, `np-help.ss`, …). Both get a synthetic `machine.def` dependency (`s/build.zuo:607-608`), which is how one `cpnanopass.ss` serves every backend.

## Tracing passes (verification tool)

The `(pass name unparser ...)` driver in `s/cpnanopass.ss:110-140` checks each pass against the tracer list and prints the unparsed IR to stderr. From a ta6le repl:

```scheme
(#%$np-tracer 'np-normalize-context)   ; add a pass to the trace list
(compile '(lambda (x y) (if (fl< x y) #f #t)))
(#%$np-tracer #f)                      ; clear
```

This is the cheapest way to get path evidence for *what shape a pass actually saw/produced* — the main instrument behind `../02-mid-end/cp0-shape-eating.md` and the recipes in `../04-verification/shape-forcing-recipes.md`.
