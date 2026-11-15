# The Flonum-Equality Select (`%fpsel=`)

*A design case study: landing the one select-family member whose compare conflates "equal" and "unordered", after the same idea had already been landed dead, removed, and only then understood. Code anchors track the `x86-64-select` branch as of `ef2396b5`.*

## Motivation

Every fixnum relop and every other flonum relop had a branchless select; `fl=` alone kept compiling to a conditional branch. The blocker is architectural: `ucomisd` sets ZF=1 on unordered *and* on ordered-equal, so no cmovcc condition distinguishes the two, and the compensating `jp` of the first attempt had a **hand-counted** skip offset that proved fragile under register coalescing. That first attempt also violated what became RULE-DEAD: it landed `%fpsel=` declared in `np-languages` with full backend clauses but no producer mapping, sat untestable, and was removed (d60a8ab1) once the rot was understood — the boolean setcc form of equality cannot serve both arm orders *at all* (no sete/setne with any single jp placement yields the else value in both orders), which nobody could see until the clauses were exercised.

## Design

Route unordered **around or to one emitted instruction**, with every displacement computed from the emitted code:

- The skip helper `fpsel-eq-skip` (`s/x86_64.ss:2681-2686`) takes an already-emitted fragment and a jp? flag, and emits `7A/7B disp` with `disp = (asm-size* frag)` — the size the register allocator and spills actually produced, never a length guess — under `safe-assert (fx<= 0 disp 127)` (rel8 bound).
- The emitters never synthesize the inverted equality condition: `cmovne` would alias on unordered. `asm-fpsel=-regs` (`:2688`) keeps the cmov in the equality direction in every aliasing case: `dest == u` gets `cmovne` + a trailing `jnp`-routed corrective move of the else value; `dest == v` and the general case preset the else value and `jp` *over* the `cmove` (unordered keeps the preset). `asm-fpsel=-imms` (`:2719`) is the same shape through the clause's scratch; `asm-fpsel=-arith` (`:2733`) materializes the exact equality bit `ZF & ~PF` as `sete` + a `jnp` skip over a re-zeroing `movi`, and a negative `A-B` takes a `neg` of the shifted bit rather than an inverted condition. `ucomisd` reads both operands before anything writes the destination, so all dest/operand aliasing is safe.

The producer side is one line — `pred->fpsel` maps `%fp=` — which also puts `fl=` behind the safe-operation wrapper flattening (`s/cpnanopass.ss:3896-3922`, `:3959`, sites `:4134`/`:4198`): the wrapper's check nest flattens and the hot path exposes the comparison, with the cold "not a flonum" error path preserved.

## Truth-table notes

The whole design lives in the unordered column of the `ucomisd` table (ZF=CF=PF=1): `a/ae/b/be`-conditioned selects need no escape (T-2) precisely because those conditions read CF, which unordered sets usefully; `e` alone reads ZF, which unordered sets *lying*. The setcc boolean form fails in both arm orders for the same reason, which is why equality's boolean materialization goes through the arith form's `ZF & ~PF` bit instead.

## Verification

Probes at o=0/o=3 cover every form (value, boolean in both arm orders — one exercising the negated-shift path, variable arms, behind a lifted effect, destination-is-then, cp0-bypassed reverse orders, safe-wrapper cases) with NaN in both operand positions, `-0.0 = +0.0`, and infinities; the emitted encodings were checked byte-for-byte; fx/fl mats pass standalone at o=0/o=3; test-some is clean across its four configurations; CI is green across the full 17-job matrix including test-more and the reboot job. The safe-wrapper cold-path messages are recorded in `root-experr-compile-0-f-f-f` (see `../04-verification/mats-experr.md`).

## Relationship to KB rules

- **RULE-TRUTH-NA** — the computed skip + rel8 bound assert is the reference implementation of the rule.
- **RULE-OPCODE** — `asm-fpsel=-arith`'s sete was first written `#x04` (the condition nibble) instead of `#x94` (`0x90|cc`); `0F 04` is undefined in long mode and SIGILLs at first execution — invisible to compilation.
- **RULE-DEAD** — the in/out/in history of this very instruction is the incident behind the rule.
- **RULE-ALIAS / RULE-UNSPILL / RULE-IMM-DOMAIN** — the regs-form aliasing dispatch, the `(z mem)` unspillable temps, and the arith base's imm32 clause guard all apply unchanged to the equality member.
