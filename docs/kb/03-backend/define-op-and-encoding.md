# `define-op` and Byte Encoding: How the Assembler Emits Machine Code

*Purpose: the mechanics of section 3 of `s/x86_64.ss` — how `define-op` builds opcode macros, how an emitter walks the reversed code-item stream, and how `asm-size` sizes placeholders. Worked example: the SSE4.1 `roundsd` family.*

## The code-item stream

Emitters never touch memory directly. An emitter is a function `(code* dest self opnd …) → code*` that prepends *code items* onto a reversed list:

- `(byte . n)`, `(word . n)`, `(long . n)`, `(quad . n)` — literal machine bytes. These are produced by the `build` macro (`s/x86_64.ss:1950` on), which validates the size keyword and the integer at macro-expansion time — a typo'd byte is a compile error, not a runtime corruption.
- `(asm ,op ,opnd …)` — a *trace item*, metadata only, contributing zero bytes. When `aop` (assembly output) is enabled, `aop-cons*` (`s/cpnanopass.ss:8852-8857`) conses it onto the stream so `s/pdhtml.ss` / `s/inspect.ss` can reconstruct a disassembly-style trace next to the raw bytes.

`np-generate-code` walks this stream twice (see [code-generation-and-relocation.md](code-generation-and-relocation.md)): first with `asm-size` to assign label offsets, then for real emission.

## `define-op` — the opcode table

`define-op` is a macro (`s/x86_64.ss:1216-1243`) with two forms:

```
(define-op mov (b w l *) binary-op #b100010)   ; :1274 — sized variants
(define-op ret  byte-op #b11000011)            ; :1305 — single variant
```

For the sized form, each suffix `b/w/l/*` generates a macro `asmop-movb` / `asmop-movw` / `asmop-movl` / `asmop-mov` (the `*` suffix names the full-machine-width variant, `quad`), each expanding to `(binary-op 'asmop-movb 'byte #b100010 …)`. For the single form it generates one `asmop-ret` macro.

The handler — `binary-op`, `unary-op`, `sse-op1`, `sse-op2`, `cmov-op`, `branch-op`, … — is an *encoding lambda* that maps `(op size encoding-constants … operands … code*)` onto byte items. `binary-op` handles the classic x86 "reg/mem with reg" encodings; `sse-op1` (:1422 on) prefixes SSE ops with the mandatory prefix and escape bytes.

`emit` (`s/x86_64.ss:1244-1249`) is thin sugar: `(emit mov a b code*)` constructs `asmop-mov` from the op name and delegates. The comment at `:1251-1253` is the house rule: **"the assembler isn't clever — you must be very explicit about which flavor you want."** Operand-size and direction decisions are made by the instruction-selection clauses in section 2, never inside an emitter.

## Worked example: `sse.roundsd`

The SSE4.1 `roundsd` instruction takes a mandatory prefix `66`, escape sequence `0F 3A 0B /r`, then a *rounding-control immediate* baked into the opcode. The family shares one encoding lambda with a different immediate per op:

```scheme
;; s/x86_64.ss:1402
(define sse-roundsd-op
  (lambda (op prefix-code map-code1 map-code2 op-code imm-code
           source dest-reg code*)
    (emit-code (op source dest-reg code*)
      (build byte prefix-code)                    ; 66
      (ax-ea-rex 0 source dest-reg #f)            ; REX after 66, before 0F
      (build byte map-code1)                      ; 0F
      (build byte map-code2)                      ; 3A
      (build byte op-code)                        ; 0B
      (ax-ea-modrm-reg source dest-reg)
      (ax-ea-sib source)
      (ax-ea-addr-disp source)
      (build byte imm-code))))                    ; rounding mode

(define-op sse.roundsd    sse-roundsd-op #x66 #x0F #x3A #x0B 0)  ; :1419
(define-op sse.floorsd    sse-roundsd-op #x66 #x0F #x3A #x0B 1)  ; :1420
(define-op sse.ceilingsd  sse-roundsd-op #x66 #x0F #x3A #x0B 2)  ; :1421
(define-op sse.truncsd    sse-roundsd-op #x66 #x0F #x3A #x0B 3)  ; :1422
```

Everything that varies per use site is a `define-op` argument (here: the immediate); everything that varies per operand (`ax-ea-rex`, `ax-ea-modrm-reg`, `ax-ea-sib`, `ax-ea-addr-disp`) is a shared addressing-mode helper. The comment inside `sse-roundsd-op` records the one non-obvious architectural fact — the REX byte goes *after* the `66` prefix and *before* the `0F` escape — because that is exactly the kind of detail that gets "corrected" by someone reasoning from the generic pattern and breaking SSE4.1 encodings.

## `emit-code` and `emit-literal-code`

`emit-code` (`s/x86_64.ss:1913-1924`) is the structured way to emit a multi-byte instruction. Its input is a sequence of *chunk expressions*, each of which must evaluate to a code item or `#f` (the `build-maybe-cons*` helper lets optional chunks — like a REX byte that is only sometimes present — drop out). It wraps the whole group in an `(asm ,op ,opnd …)` trace item via `aop-cons*`. All the `define-op` handlers use it, which is why the trace and the bytes can never desynchronize.

`emit-literal-code` (`:1926-1930`) is the escape hatch for sequences too irregular for a reusable handler: you write the bytes yourself as hex-like literals and `encode-hex-like` (`:1932-1947`) reparses them as hexadecimal at macro-expansion time. Its canonical users are the hand-built `setcc`-plus-`shl`/`add` tails of `asm-isel-bool` and `asm-fpsel-bool` (`s/x86_64.ss:2497-2507`, `:2581-2590`), where the comment lines between the byte lists *are* the disassembly (`; shl dest, 3`, `; add dest, 6`). Because these bytes implement the boolean-materialization identity from [`flags-truth-tables.md`](flags-truth-tables.md), the literal encoding is reviewed under the same RULE-TRUTH / RULE-TRUTH-NA regime as any flags-consuming sequence (see `x86_64-backend.md` contract cards and `../04-verification/review-checklists.md`).

## `asm-size` — sizing the stream

```scheme
;; s/x86_64.ss:2117
(define asm-size
  (lambda (x)
    (case (car x)
      [(asm x86_64-jump x86_64-call x86_64-popcount x86_64-fpround) 0]
      [(byte) 1] [(word) 2] [(long) 4] [else 8])))
```

Two facts in one small function:

1. Trace items (`asm`) are size 0 — the disassembly metadata costs no space, and the first sizing pass (`asm-size*`, `s/cpnanopass.ss:8844-8846`) can ignore them.
2. **Placeholder ops are size 0** (`x86_64-jump`, `x86_64-call`, `x86_64-popcount`, `x86_64-fpround`). These stand for instructions whose final size depends on relocation decisions (e.g. jump reachability) or on runtime CPU features; they are patched in by the relocation/linking layer after `c-mkcode` turns stream items into relocation records (see [code-generation-and-relocation.md](code-generation-and-relocation.md)). A placeholder whose true size were nonzero would desynchronize every label offset computed in the first pass — the invariant is "size 0 now, real size decided at link time".

## Review implications

- New encodings reuse an existing handler lambda when one fits; a new handler documents its non-obvious byte-order facts inline the way `sse-roundsd-op` does (RULE-PRODUCERS-style argumentation about which operand shapes can reach it lives in the instruction-selection clause, see [instruction-selection.md](instruction-selection.md)).
- `build` checks sizes at expand time; `emit-code` keeps trace and bytes together; `asm-size` keeps sizing honest. A change that bypasses any of the three needs a justification in the PR.
