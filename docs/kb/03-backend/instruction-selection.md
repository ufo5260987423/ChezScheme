# Instruction Selection: `define-instruction`, `select-instructions!`, and Scratch-Discipline

*Purpose: how L15c `(set! live lhs rhs)` becomes `(asm ,op ,opnd …)`, what `coerce-opnd` really does, and why scratch registers must be bound by a plain `set!` before the self-referential `asm` (RULE-UNSPILL, commit `5b6227fb`).*

## Where it sits

`select-instructions!` is a nanopass pass (`s/cpnanopass.ss:10203-10204`):

```
define-pass select-instructions! : (L15c Dummy) (ir block* live-size
  reg-spillinfo force-overflow?) -> (L15d Dummy) ()
```

It is the sixth step inside `np-allocate-registers` (`s/cpnanopass.ss:10886`), after live analysis and frame assignment have fixed the frame layout and before graph coloring picks register homes. This ordering matters: instruction selection runs on *pre-colored* L15c, introduces its scratch registers as new locals (`local*` is threaded through the whole RA pass), and lets the coloring phase place them. The full sequence, with lines:

```
do-live-analysis!            s/cpnanopass.ss:9042
record-call-live!            :9276
do-spillable-conflict!       :9350
assign-frame!                :9460 (module) / :9473
assign-new-frame!            :9569 (module) / :9588
finalize-frame-locations!    :9814
select-instructions!         :10203
  → graph coloring: set-home! (:10603), pick-victims (:10622),
    Chaitin-style spill-and-retry loop in np-allocate-registers
```

`np-allocate-registers` is a `define-pass` (:10886) whose body is an unrolled pipeline of `RApass` macro invocations (:10915-11000), each wrapping one sub-pass with a block-graph printer for debugging.

## The `define-instruction` macro

`define-instruction` (`s/cpnanopass.ss:10013`) is the contract language of section 2 of each backend `.ss`. A clause looks like:

```scheme
;; s/x86_64.ss:490-499
[(op (z ur) (x ur) (y ur) (u ur) (v ur))
 `(set! ,(make-live-info) ,z
    (asm ,null-info
         ,(asm-isel-regs (case op [(isel<) #x0C] ...))
         ,z ,x ,y ,u ,v))]
```

The macro expands each clause into a matcher over `(set! live lhs rhs)` where the operand pattern `(z ur) (x ur) …` is translated via `coercible?*` (`s/cpnanopass.ss:9999-10010`) — each operand type (`mem`, `fpmem`, `ur`, `fpur`, `xur`) becomes a predicate test:

- `mem`/`fpmem` check the operand is a memory reference;
- `ur` is anything *except* FP (`safe-assert (not (or (fpur? x) (fpmem? x)))`);
- `fpur` accepts FP registers *and* FP memory.

**First matching clause wins.** This makes clause *order* part of the semantics — the select family deliberately lists its `(z mem)` clauses before the `(z ur)` clauses so a memory destination never falls into a `ur` clause (see the contract cards in [x86_64-backend.md](x86_64-backend.md) and the history below).

When a clause matches, the coercion machinery may rewrite operands *before* the clause body runs: `coerce-opnd` calls (`s/cpnanopass.ss:10039`, :10055, :10074) ask the backend to route an incompatible operand through a scratch. That is the backend's section-2 `coerce-opnd` (`s/x86_64.ss:167-207`), whose workhorse is `mem->mem` (`:140-150`): for a memory-to-memory instruction it allocates a scratch register, emits the load, and substitutes the register into the asm. Note the shape: **the scratch is bound by a plain `set!` that precedes the asm**, never by making the asm self-referential.

## Scratch disciplines: `make-tmp` / `make-unspillable` / `make-precolored-unspillable`

Three helpers, three different contracts (all in `np-allocate-registers`'s scope):

- `make-tmp` (`s/cpnanopass.ss:9872-9878`) — a normal new local, register-allocatable, spillable. Use for values with a simple def-use shape (e.g. the preset of the select then-value).
- `make-unspillable` (:9873, imported from `np-languages`) — a local that must receive a register and **must not be spilled**. The unspillable-conflict walk (`do-spillable-conflict!`, :9350) records conflicts so coloring can honor that.
- `make-precolored-unspillable` (:9884) — pinned to a specific register in addition (e.g. `%xp` at :10353).

## RULE-UNSPILL: the `(z mem)` clause history

The normative rule (checklist A of `../04-verification/review-checklists.md`):

> **[RULE-UNSPILL]** Any new scratch introduced in an instruction > clause is assigned by a plain `set!` before the self-referential > `asm` (unspillable-conflict walk requirement; see the `(z mem)` > clause history, commit `5b6227fb`).

Origin. The select family's memory clauses need a scratch for the selected value before storing to memory. An early shape let the `ur`-typed destination clause handle memory destinations by routing the store through an instruction-selection temporary — but the temporary then appeared as its own destination *inside* the self-referential select asm (`t` both written by the asm and read as an operand). The unspillable-conflict walk cannot model a value whose def and a conflicting use live in the *same* asm node: the walk assumes defs happen at `set!` boundaries. Result: a latent conflict miscompile. Commit `5b6227fb` ("x86_64: preset the select temp for memory destinations") fixed it by

1. listing the `(z mem)` clauses **first** in each select instruction (so `ur` never sees memory), and
2. presetting the scratch with a plain `(set! live t v)` before the asm — giving the walk a clean def point it can reason about.

The comments now at `s/x86_64.ss:416-422` and `:538-545` state both parts explicitly; treat them as load-bearing.

## What instruction selection does *not* decide

- **Operand sizes and directions** — settled by the clause/emitter, per the "assembler isn't clever" rule ([define-op-and-encoding.md](define-op-and-encoding.md)).
- **Condition-code semantics** — every flags-consuming choice is derived from [`flags-truth-tables.md`](flags-truth-tables.md) (RULE-TRUTH); the `setcc-cc`/`invert-cc-select` helpers in the clause definitions (`s/x86_64.ss:405`, `:521`, `:528`) exist so the arm-order variation is absorbed here and emitters see a normalized "select strue" condition (R-1/R-2).
- **Spilling** — a coloring iteration that cannot color picks victims (`pick-victims`, :10622), spills them to frames, and reruns assign-frame! + select-instructions! until convergence.

## Review implications

Section A of `../04-verification/review-checklists.md` applies in full to any new clause: producers enumerated (RULE-PRODUCERS — which passes can emit this IR shape, argued via `select-if`/`select-tail`/ cpprim reachability per `../04-verification/reachability-rule.md`), arm-order symmetry checked (RULE-SYM), alias dispatch at emit time (RULE-ALIAS), and scratch discipline per the above (RULE-UNSPILL).
