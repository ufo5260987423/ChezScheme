# The pb Backend: Portable Bytecode, Interpreter, and C Chunks

*Purpose: the full pb (portable bytecode) backend — how it reuses the native-backend architecture with one indirection, how opcodes become C via generated enums, how `S_pb_interp` executes them, and how hot segments are translated to C chunks. Includes the comparison table against native backends.*

## Concept

Every native backend (`x86_64`, `arm64`, `riscv64`, `loongarch64`, `ppc32`, `arm32`) compiles L16 to real machine bytes through its own section-3 assembler. The pb backend replaces *only the last indirection*: `s/pb.ss` emits fixed-width 32-bit bytecode instructions whose opcodes are enumeration constants (`pb-add`, `pb-i->i`, …), and execution is either the C interpreter `S_pb_interp` or C functions translated from hot bytecode segments. One compiled image runs on every platform — that is the entire point of the machine type `pb`/`tpb` and of the pb `.def` family (see [machine-def-files.md](machine-def-files.md)).

The machine description confirms the "one code, all platforms" design: `s/pb.def:1-6` sets `machine-type-pb` and includes `pbcommon64.def`; `s/pbcommon.def:1` sets `architecture 'pb`, `:13` sets `asm-arg-reg-max 7`, `:22` sets `unaligned-floats #f`; the concrete per-platform files (`pbarch.def`/`tpbarch.def` with `'Mend` endianness and `'Mword` width filled by `get-machine-files`, `s/machine.zuo:24-47`) vary only data layout, never the instruction set.

## Scheme side: `s/pb.ss`

The file is structurally the native backend with byte emission swapped for enum emission:

- **Instruction selection** uses the same `define-instruction` macro and the same clause style (`s/pb.ss:229` on — `(define-instruction value (- -/ovfl -/eq -/pos))`, `(+ +/ovfl +/carry)`, …). The comments at `:160-170` record the deliberate simplification: `define-instruction` code takes care of `ur`/`fpur` itself and does not try to cover every operand combination the native backends do, because the bytecode format is uniform.
- **`define-op`** (`:645` on) has the same shape as the native one ([define-op-and-encoding.md](define-op-and-encoding.md)) but the "encoding constant" is an enum value, not a machine byte: `(define-op add signal-bin-op (constant pb-add))` (`:673`), and likewise `sub`/`mul`/`div`/`land`/… each carrying its `pb-*` constant. The handler lambdas (`mov-op`, `bin-op`, `signal-bin-op`, `un-op`, …) pack operands into the 32-bit instruction word instead of emitting REX bytes.

## The enum contract: `s/cmacros.ss`

`define-pb-enum` (`s/cmacros.ss:3218`) generates both the Scheme constants and the C header values from one source. The families:

- `pb-move-types` (:3313) — `pb-i->i`, `pb-d->d`, bit/slice moves;
- `pb-binaries` (:3327), `pb-unaries` (:3346), `pb-compares` (:3350), `pb-branches` (:3361), `pb-shifts` (:3366);
- sizes and argument types from `pb-sizes` (:3301) and `pb-argument-types` (:3292).

Because both sides are generated from the same `(constant …)` / `define-pb-enum` forms, the Scheme emitter and the C interpreter can never drift on opcode numbering — the same single-contract pattern as `scheme.h`/`equates.h` from `s/mkheader.ss` for native targets ([machine-def-files.md](machine-def-files.md)).

Virtual-machine resources are constants too: `pb-reg-count` (16 on pb, else 0) at `s/cmacros.ss:1421`, `pb-call-arena-size` (128 on pb) at :1423, and the thread-context layout fields `pb-regs` … `pb-call-arena` (:1662-1664) with the comment that "`pb.c` assumes that `pb-regs` through `pb-call-arena` are together" — the struct layout *is* an ABI.

## C side: `c/pb.h` + `c/pb.c`

`c/pb.h` is hand-written and small:

- `machine_state` (`c/pb.h:4-10`): `machine_regs[pb_reg_count]` + `machine_call_arena[pb_call_arena_size]` — the virtual registers live inside the thread context (`tc`), so no real registers are reserved; `call_arena` (:14) stages arguments for C calls.
- `INSTR_*` bit-field decode macros (`c/pb.h:22` on): `INSTR_op` takes the low 8 bits as the opcode, with d/r/i field extractors alongside.
- **145 `doi_*` macros** — one per (opcode × operand-shape) combination, each expanding to the few C statements implementing that instruction (e.g. `doi_pb_mov_pb_i_i` at :181). The count is large because pb is orthogonal: move/binary/unary × int/float × size/width variants.

`c/pb.c`:

- `Sregister_pbchunks` (`:25`) registers translated C chunks with the interpreter;
- `S_pb_interp` (`:53`) — the dispatch loop: fetch 32-bit instruction, decode via `INSTR_*`, execute `doi_*`, repeat;
- a nested `S_pb_interp` call at :244 for chunk-to-chunk transitions.

Calls out to C (foreign procedures, runtime routines) go through `machine_call_arena` — arguments are staged in the arena and the call goes out via libffi, so pb needs no per-platform ABI knowledge in the emitted code.

## pbchunks: bytecode → C

`s/pbchunk.ss` translates hot bytecode *segments* into C functions (`pbchunk_*.c`) that are registered back into the interpreter:

- records: `chunk-info` (:17), `chunklet` (:27), `label` (:39);
- `fasl-pbchunk!` (:46) drives the translation, emitting a registration stub per chunk (`write-registration`, :93) with start/end indices;
- `s/bootpbchunk.ss` performs the same translation for boot code.
- The build decides whether registration is needed: `need-pbchunk-register?` (`c/build.zuo:657`, used at :454) checks whether the target configuration has pbchunks to register.

## pb vs native backends

| Aspect | Native (e.g. x86_64) | pb |
|---|---|---|
| Backend file | `s/x86_64.ss` (spliced per `architecture`) | `s/pb.ss` |
| `define-op` payload | machine-byte encodings (`binary-op`, `sse-op1`, …) | `pb-*` enum constants (`s/pb.ss:673` on) |
| Instruction width | 1-15 bytes, variable | fixed 32-bit |
| Execution | direct | `S_pb_interp` (`c/pb.c:53`) or registered C chunks |
| Register model | real registers via `define-registers` | 16 virtual regs in `machine_state` (`c/pb.h:5`) |
| ABI for C calls | `%Carg*` aliases, per-OS variants | `machine_call_arena` + libffi (`c/pb.h:9`) |
| Capability bits | per-arch `.def` opts-in (`s/a6.def:13-15`) | `pbcommon.def` only; uniform semantics |
| Machine description | `<arch>.def` + `unix.def` templates | `pb.def`/`pbarch.def` + `pbcommon*.def` |
| Chunk acceleration | n/a | `s/pbchunk.ss` → `pbchunk_*.c` |
| `.def` selection | `arch->backend`, `s/machine.zuo:7` | same function, pb branch `:24-47` |

## What pb means for the verification layer

pb's uniform instruction set removes most operand-shape hazards (no REX bytes, no aliasing degrees of freedom), but the *semantic* contracts of the select family still apply — the `isel`/`fpsel` conversions in `np-normalize-context` are architecture-gated by `setcc-instruction`, and pb's `.def` family sets no such bit, so pb keeps the branchy forms. When reasoning about whether a fix needs a pb counterpart, check whether the pass code is inside a `(constant-case setcc-instruction …)` or `(architecture …)` guard ([machine-def-files.md](machine-def-files.md)) before assuming pb is affected.
