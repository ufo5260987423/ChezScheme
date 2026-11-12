# Imposing Calling Conventions (`np-impose-calling-conventions`)

How lambda clauses stop having formals and calls stop having arguments: the pass that materializes frame layout, argument/result movement, and case-lambda dispatch, `s/cpnanopass.ss:4282` (L12.5 → L13). See `../01-nanopass/the-l1-l16-ladder.md` for the language levels and `basic-blocks.md` for what happens to the `new-frame`/`return-point` forms afterwards.

## Language delta: L12.5 → L13

L12.5 (`s/np-languages.ss:1013-1019`) is tiny — it only removes `trap-check` from `Effect` (the checks have been placed by `np-insert-trap-check`, `:4265`). L13 (`:1029-1102`) is a ground-up `define-language` (no `extends`), and its header comment (`:1025-1028`) is the contract:

> calling conventions are imposed; clauses no longer have formals (they > are now locals set by arguments from argument registers and frame); > calls no longer have arguments; case-lambda is responsible for > dispatching to correct clause, even when the game is being played

What actually changes:

- `Expr` loses `call`, `let`, bare `if`/`seq`; a clause body is a `Tail` and everything else is an `Effect` sequence.
- `Tail` gains `jump t (var* ...)` (tail call), `joto l (nfv* ...)` (local jump carrying non-frame variables), `asm-return reg* ...`, `asm-c-return`.
- `Effect` gains the frame vocabulary: `new-frame info rpl* ... rpl`, `return-point info rpl mrvl as-fallthrough (cnfv* ...)`, `rp-header mrvl fs lpm`, `remove-frame info`, `restore-local-saves info`, `shift-arg reg imm info`, `check-live reg* ...` (`:1074-1094`).
- New terminals: `fv` (frame variable), `max-fv`/`offset` fixnums, `reg`, `return-label` (`mrvl`), `as-fallthrough` boolean (`:1031-1048`).
- `hand-coded sym` appears as a `CaseLambdaExpr` (`:1053`) — stubs the next pass expands.

## What the pass does

Defined at `s/cpnanopass.ss:4282`; imports the assembler entry points `asm-foreign-call`, `asm-foreign-callable`, `asm-enter` from `asm-module` (`:4290` — the same module described in `../00-overview/compilation-pipeline.md`).

- **Formals → locals.** `set-formal-registers!` (`:4307-4314`) walks the clause's formals and `uvar-location-set!`s the first N to `arg-registers` (defined per machine by `define-registers`, `s/np-register.ss:104`); remaining formals become frame slots.
- **Call arguments → movement code.** `get-arg-regs` (`:4315-4322`) splits an argument list into register-held and frame-held prefixes. `build-tail-call` / `build-nontail-call` / `build-mv-return` (module at `:4323`) emit the corresponding `set!`s: argument values into argument registers, excess into the outgoing frame area, then a `jump` (tail) or a `new-frame`/`return-point` sequence (non-tail). Symbol and library references get special-cased via `symref?` / `libref?` (`:4324-4339`).
- **Case-lambda dispatch.** Since calls no longer carry arity, each case-lambda must dispatch internally: `np-flatten-case-lambda` (`:4133`, L11→L12) already split each clause into an `entry-point` (`s/np-languages.ss:1003`) and added `do-rest` for variable-arity clauses (`:1006`); this pass wires the entry labels so a call lands on the matching clause (or the wrong-arity error path).
- **Multiple values.** `mrvl` (multiple-return-value label) parameters thread the extra-results destination through `rp-header`/`mvset` shapes; single-value contexts get the `as-fallthrough` treatment.
- **Frame bookkeeping.** `max-fv` per lambda tracks the frame size; `fv` variables name frame slots; `shift-arg`/`remove-frame`/ `restore-local-saves` are the adjacency fixes around calls (the allocation pointer exposure and block flattening passes later rely on this exact vocabulary — L14 removes `alloc`, see `np-expose-allocation-pointer` at `:7038`).
- It also defines the type-check predicate generator used in traces: `define-$type-check` (`:4298`).

## Frame layout as seen by later passes

An L13 non-tail call region reads, in order: `new-frame` (opens the outgoing frame, `info` carries source/sexpr), argument `set!`s into the frame, `return-point` (marks where control returns; `cnfv*` are the callee-saved/non-frame vars live across the call), the call itself (disappears into a `jump`-ish tail via hand-coded stubs in `np-expand-hand-coded`, `:5977`), then `remove-frame` / `restore-local-saves` / `shift-arg` on the continuation. `np-expose-basic-blocks` (`:7253`) turns each `new-frame` into a `newframe-block` with explicit return-point links (`:7343-7353`) — the shape register allocation lays out and `np-generate-code` (`:8437`) emits.

## Verification hooks

- `(#%$np-tracer 'np-impose-calling-conventions)` shows clauses with locals only and calls replaced by register/frame movement plus `jump`/`new-frame` sequences.
- o=0..3 all run this pass; differences show up as how much cp0/cpprim simplified before it, not in the conventions themselves.
