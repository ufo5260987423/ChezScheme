# Machine Description Files: the `.def` System and Capability-Bit Gating

*Purpose: how a machine type string like `ta6le` becomes a concrete `machine.def`, what may live in a `.def` file, and how capability bits such as `setcc-instruction` gate backend features. Read this before touching any `.def` file or adding an architecture-conditional pass.*

## From machine type to `machine.def`

A machine type is a compact string: `ta6le` = thread prefix `t` + arch `a6` + OS `le`. `s/machine.zuo` is the single place that decodes it:

- `arch->backend` (`s/machine.zuo:7-14`) maps the arch component to a backend file: `a6 → x86_64`, `i3 → x86`, `rv64 → riscv64`, `la64 → loongarch64`, `armv7 → arm32`, anything else passes through unchanged (`pb` stays `pb`).
- `get-machine-files` (`s/machine.zuo:20`) splits `m`: `threaded?` tests whether the first char is `t` (:21), `uni` is the remainder (:22). For a native arch it then selects a concrete `machine.def`: if `<m>.def` exists it is copied verbatim (:55-58); otherwise the template `tunix.def` (threaded) or `unix.def` (:60-63) is filled via `fill-template` with `'M m 'March arch`, so `$(M)` becomes the machine type and `$(March)` the arch (:59-63). For `a6` an extra synthesized dependency `a6-options.def` is added with the `x86-64-level` substituted (:66-68, `add-a6-options`).
- The pb path (:24-47) works the same way with `pb.def`/`tpb.def` copied directly and `pbarch.def`/`tpbarch.def` filled with `'Mend` endianness plus `'Mword` width.

The returned file list (template + `default.def` + `<arch>.def` + optional `<os>.def`) is what the compiler's `(constant …)` / `(constant-case …)` / `meta-cond` forms read at expand time. The backend file itself is chosen by the `architecture` constant, which the `architecture` macro in `s/np-register.ss` uses to splice in the right `<arch>.ss` (see `../00-overview/compilation-pipeline.md`).

## What may live in a `.def` file

Only three forms, and nothing else:

1. `(define-constant name value)` — mandatory constants.
2. `(define-constant-default name value)` — overridable defaults, collected in `s/default.def:2-49`.
3. `(features …)` — feature flags such as `iconv`, `expeditor`, `pthreads` (`s/unix.def:5`, `s/tunix.def:5`).

No procedures, no pass logic. This restriction is what lets the same constants drive three consumers at once: the Scheme compiler (`(constant …)`), the C runtime via generated headers (`s/mkheader.ss` produces `scheme.h`/`equates.h` from the same constant source), and the nanopass languages themselves.

### Concrete files

- `s/a6.def:1-17` — x86-64 proper: `architecture 'x86_64` (:1), `ptr-bits 64` (:2), `asm-arg-reg-max 5` / `asm-arg-reg-cnt 3` (:4-5, the Scheme-argument register budget used by `define-registers`, `s/np-register.ss:52-67`), `popcount-instruction #t` (:13), `fpround-instruction #t` (:14), `setcc-instruction #t` (:15), then `(include "a6-options.def")` (:17).
- `s/a6-options.def:1` — one line: `(define-constant x86-64-level $(level))`, filled by `configure --x86-64-level` through `add-a6-options` in `s/machine.zuo`.
- `s/unix.def:1-7` / `s/tunix.def:1-7` — templates: `machine-type` from `$(M)`, features, `(include "$(March).def")`, `(include "default.def")`.
- `s/default.def:2-49` — portable defaults and the gating defaults for capability bits: `popcount-instruction #f` (:44), **`setcc-instruction #f` (:45)**, `fpround-instruction #f` (:46), `sqrt-instruction #f` (:47), `fence-instruction #f` (:48), `integer-divide-instruction #f` (:43). An arch that has the capability opts in with an explicit `#t`; every other arch gets the `#f` default automatically.
- pb machine descriptions: `s/pb.def:1-6` sets `machine-type-pb`, no features, and includes `pbcommon64.def`; `s/pbcommon.def:1` sets `architecture 'pb`, `:13` sets `asm-arg-reg-max 7`, `:22` sets `unaligned-floats #f`. See [pb-backend.md](pb-backend.md).

## Capability-bit gating pattern

The rule (checklist section C, `../04-verification/review-checklists.md`): **architecture gating uses a `.def` capability bit, not `architecture` checks scattered through passes.** The canonical instance is `setcc-instruction`:

```
(define-constant setcc-instruction #t)         ; s/a6.def:15
(define-constant-default setcc-instruction #f) ; s/default.def:45
```

and the consumer in the mid-end:

```scheme
;; s/cpnanopass.ss:3769
(define pred->fpsel
  (constant-case setcc-instruction
    [(#t) (lambda (prim) ...)]
    [else (lambda (prim) #f)]))
```

`pred->isel` (`s/cpnanopass.ss:3746`) is structured identically. When the bit is `#f` the branchless-select conversion simply declines every predicate, and the backend's `isel`/`fpsel` clauses are dead code — never reached, so never wrong. This is the cheapest possible correctness argument for a new arch: omit the capability and the feature vanish cleanly, instead of miscompiling.

`constant-case` resolves at *expand* time (it is a `meta-cond`-style form over `(constant …)`), so the `#f` branch costs nothing at run time and the compiler binary for a non-x86 target contains no select conversion at all.

### When adding a new capability bit

1. Add `define-constant-default <bit> #f` to `s/default.def` next to the existing bits (:43-49).
2. Opt in per arch with `define-constant <bit> #t` in `<arch>.def`.
3. Gate the pass code with a single `(constant-case <bit> …)` at the conversion site, the way `pred->isel`/`pred->fpsel` do — not with per-clause `architecture` comparisons.
4. If the C runtime needs to know, expose the constant via `s/mkheader.ss` so `scheme.h`/`equates.h` stay the single Scheme↔C contract (see [pb-backend.md](pb-backend.md) for the enum-generation analogue).

## Relationship to the rest of the backend

The constants defined here are read by every layer below: `asm-arg-reg-max`/`asm-arg-reg-cnt` size the argument-register lists in `define-registers` (`s/np-register.ss:52-67`, macro at :104 — see [x86_64-backend.md](x86_64-backend.md)); the backend `.ss` files' `(if-feature windows …)` reads the features; and the C ABI layer (`s/foreign.ss`, `c/foreign.c`, `c/ffi.c`) uses the same generated headers, so a register-count change never desynchronizes the two sides of a foreign call.
