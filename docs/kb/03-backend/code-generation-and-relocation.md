# Code Generation and Relocation: From L16 Byte Stream to Linked Code Object

*Purpose: the last two compiler stages — `np-generate-code`'s two-pass chunk emission and the `c-mkcode` → `s/reloc.ss` → C (`c/prim5.c`, `c/prim.c`) relocation pipeline that turns placeholders into runnable addresses. Line numbers verified against the current `sel-stage3` checkout.*

## Stage 1: `np-generate-code` (`s/cpnanopass.ss:8437`)

`define-pass np-generate-code : L16 (ir) -> * (code)` consumes the L16 basic-block graph produced by register allocation and produces, per code object, a reversed stream of code items (`(byte . n)` / `(word . n)` / `(long . n)` / `(quad . n)` / `(asm ,op ,opnd …)` traces — see [define-op-and-encoding.md](define-op-and-encoding.md)) plus a `funcrel*` relocation list.

### Chunk records

Emission is organized as *chunks* — records of already-emitted code with pending label fixups:

| Record | `s/cpnanopass.ss` | Holds |
|---|---|---|
| `chunk` | :8389 | a sized prefix (`(asm-size* code*)`, :8394) and the code list |
| `lchunk` | :8395 | a chunk with a label to bind |
| `gchunk` | :8404 | a chunk holding a global/object reference |
| `cgchunk` | :8413 | a *conditional-goto* chunk (two targets) |
| `rachunk` | :8427 | a *return-address* chunk (Scheme calling convention) |

The label-offset problem: `asm-jump` / `asm-conditional-jump` / `asm-return-address` items must encode PC-relative displacements to labels, but a label's offset is only known once everything before it has been sized. Solution: **two passes**.

1. **Sizing pass** — walk the stream, `asm-size` each item (`asm-size*`, :8844; sizes in `s/x86_64.ss:2117`), accumulate label offsets. Placeholder ops (`x86_64-jump`, `x86_64-call`, `x86_64-popcount`, `x86_64-fpround`) report size 0 here; their real bytes arrive at link time.
2. **Emission pass** — re-walk with real offsets. Jumps compute relative displacements against the label offsets from pass 1 (`asm-jump` at :8542 and :8696, `asm-conditional-jump` at :8550); return-address chunks call `asm-return-address` (:8557, :8806) and `asm-rp-header` (:8880) with the function's code size so the Scheme return-address protocol (rp-header size, compact-header adjustment via `adjust-return-point-offset`, :8867) is honored. `asm-data-label` (:8875) emits absolute references to data labels.

Between the passes, `resolve-funcrel!` (:8731) settles `funcrel*` entries accumulated by `make-funcrel` (:8367-8371): each entry is `(reloc-type code-offset . label-or-object)`, threaded through the `funcrel*` variable (:8365) during emission and reversed at the end.

### Triv → operand

`Triv->rand` (:8819) maps an L16 `Triv` onto the machine operand representation the emitters expect; the `Trivit` macro (:8849) binds a whole operand list at once — every emitter in section 3 of `s/x86_64.ss` is written inside `Trivit` for this reason.

## Stage 2: `c-mkcode` (`s/compile.ss:86`)

`c-mkcode` walks the code list of each code record and materializes the bytes into a freshly created code object (`$make-code-object`):

- literal items via `$set-code-byte!` / `$set-code-word!` / `$set-code-long!` / `$set-code-quad!` (`s/compile.ss:116-133`), addressed from `code-data-disp`;
- `asm` items become **relocation records**: `reloc-abs` (:137), `reloc-rel` (:147), `reloc-x86_64-jump` (:208), `reloc-x86_64-call` (:212), `reloc-x86_64-popcount` (:216), `reloc-x86_64-fpround` (:220) — plus the per-arch families (`reloc-arm64-*`, `reloc-riscv64-*`, `reloc-pb-*` further down the same function). Each record is `(reloc-type item-offset (fx- code-offset reloc-offset))`, i.e. it remembers *where in the code object* the patchable cell is and *what* must be patched in.

## Stage 3: `s/reloc.ss` — the Scheme→C bridge

`$make-relocation-table!` (`s/reloc.ss:23`) collects the reloc records and foreign entries into the code object's relocation table by calling two foreign procedures registered in C:

- `(cs)link_code_object` (`s/reloc.ss:26`), registered in `c/prim.c:209`, implemented as `s_link_code_object` (`c/prim.c:318-`); it iterates the relocation table (`RELOCIT`/`RELOC_EXTENDED_FORMAT`) and patches each entry against the object vector;
- `(cs)s_set_reloc` (`s/reloc.ss:30`), declared at `c/prim5.c:73`, implemented at `c/prim5.c:1037-1044` — writes one unaligned uptr into the table (`STORE_UNALIGNED_UPTR`) with fixnum/int conversion; registered at `c/prim5.c:1789`.

The byte/word/long/quad writers of stage 2 likewise bottom out in `c/prim5.c` (`s_set_code_byte/word/long/quad`). This is the only crossing between the Scheme-side stream and the C runtime; keeping it narrow (one reloc table + one linker) is deliberate.

## Stage 4: serialization and debugging

- `s/fasl.ss` / `s/vfasl.ss` serialize the linked code objects into `.so`/boot files, relocations included, so a fasled code object is re-linked (not re-emitted) at load time.
- `s/pdhtml.ss` and `s/inspect.ss` consume the `(asm ,op ,opnd …)` trace items — which is why emitters are required to emit them via `emit-code`/`aop-cons*` and why they are size 0 ([define-op-and-encoding.md](define-op-and-encoding.md)). The assembly-output trace (`c-trace` inside `np-generate-code`, :8441-8460) pairs each trace item with its byte offset for `disassemble` output.

## The whole path, one line

```
L16 blocks
  → np-generate-code  (two-pass sizing/emission, funcrel*)
      s/cpnanopass.ss:8437
  → c-mkcode          (bytes + reloc records)
      s/compile.ss:86
  → s/reloc.ss        ($make-relocation-table!)
  → c/prim5.c + c/prim.c (s_set_reloc, s_link_code_object)
  → code object → s/fasl.ss / s/vfasl.ss → .so / boot
```

Backend emitters changed under the select-incident rules (see `x86_64-backend.md`, [`flags-truth-tables.md`](flags-truth-tables.md)) surface here as changed byte streams; the verification layer that proves they execute is `../04-verification/` and the executable cross-checker in `../tools/`.
