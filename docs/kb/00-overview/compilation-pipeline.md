# The Compilation Pipeline

The map every other article assumes. Each stage lists its input/output representation and its anchor in the source tree.

## Top level

```
source text
  │  read                                  (s/read.ss)
  ▼
macro expansion (expand)                   expander, output Lexpand
  ▼
$uncprep / cprep                           (s/cprep.ss — fills preinfo sexpr fields)
  ▼
cp0                                        (s/cp0.ss — source-level optimizer)
cptypes                                    (s/cptypes.ss, s/cptypes-lattice.ss — type recovery)
cpletrec                                   (s/cpletrec.ss)
cpcheck                                    (s/cpcheck.ss)
cpcommonize                                (s/cpcommonize.ss — cross-lambda CSE)
  ▼
$cpnanopass / $np-compile                  (s/cpnanopass.ss — the nanopass ladder, see below)
  ▼
machine code (code object + relocations)
```

The driver is `compile` in `s/compile.ss:828`; the same sequence appears at `s/compile.ss:1813` (`compile-file-help`). `$np-compile` itself is at `s/cpnanopass.ss:11146`.

## The nanopass ladder (s/cpnanopass.ss)

`$np-compile` (`s/cpnanopass.ss:11146`) composes ~40 passes over the language family L1→L16 defined in `s/np-languages.ss`. The stages that matter for codegen:

### Front half: Scheme → machine-friendly core

| Pass | Line | Language | Role |
|---|---|---|---|
| `cpnanopass` | :683 | Lsrc→L1 | core-form canonicalization |
| `np-recognize-let` … `np-name-anonymous-lambda` | :752–:1405 | →L5 | lexical restructuring |
| `np-convert-closures` + friends | :1418–:2092 | →L6/L7 | closure conversion and optimization |
| `$np-expand-primitives` (in s/cpprim.ss) | — | →L9 | primitive expansion; **safe ops become nested type checks around unsafe inlines here** |
| `np-place-overflow-and-trap` … `np-flatten-case-lambda` | :3027–:3932 | →L9.5…L12.5 | checks, context normalization |
| `np-optimize-pred-in-value` | :3302 | L9.75 | pred-in-value conversion; **rewrites `(if p #f #t)`-style value shapes before the backend ever sees them** — see `../02-mid-end/cp0-shape-eating.md` |
| `np-normalize-context` | :3740 | L10.5→L11 | **the branchless-select conversion lives here** (`pred->isel`/`pred->fpsel`, `select-if`/`select-tail`, `lift-seq-pred`) |

### Back half: conventions → machine code

| Pass | Line | Language | Role |
|---|---|---|---|
| `np-impose-calling-conventions` | :4282 | →L13 | frames, argument/result movement |
| `np-expand-hand-coded` | :5977 | →L13.5 | hand-coded entry/runtime routines |
| `np-expose-allocation-pointer` | :7038 | →L14 | |
| `np-expose-basic-blocks` | :7253 | →L15a | flatten to basic-block graph |
| block-graph utilities | :7491–:8280 | L15a | repeater removal (:7491), pariah propagation (:7544), profiling (:8068), in-links (:8161), loop depth (:8183), reference weights (:8280) |
| **`np-allocate-registers`** | :10886 | L15a→L16 | live analysis, conflicts, frame assignment, **`select-instructions!`** (:10203; module at :9867: IR → `(asm ,op ,opnd ...)`), Chaitin-style graph coloring with spill-and-retry |
| `np-generate-code` | :8437 | L16 → code | two-pass chunk emission, relocations (`funcrel*`, `make-funcrel` :8367) |

## The machine backend (s/x86_64.ss, one per architecture)

Each `<arch>.ss` is spliced into the compiler by the `architecture` macro at the top of `s/np-register.ss` and has three sections:

1. **Registers** — `define-registers` (`s/np-register.ss:104` macro); `%Carg1..8`/`%Cfparg1..8` mark the C ABI argument registers.
2. **Instruction selection** — a `module` exporting `md-handle-jump`, `coercible?`, `coerce-opnd` (operand constraints; module head at `s/x86_64.ss:94`), plus `define-instruction` clauses that map IR operations onto `asm-*` emitters. The `define-instruction` macro itself is at `s/cpnanopass.ss:10013`.
3. **Assembler** — `module asm-module` (`s/x86_64.ss:1166`), the `define-op` opcode table (:1216), `emit` (:1244), `emit-code` (:1913), and the `asm-*` emitter functions exported to instruction selection.

Machine *descriptions* live in `.def` files (`s/a6.def`, `s/a6-options.def`, `s/unix.def`/`nt.def`, `s/default.def`) — pure constants (register counts, capability bits like `setcc-instruction`); `s/machine.zuo` synthesizes the concrete machine's `machine.def` from templates and picks the backend file.

## Code object birth (machine code → runnable)

1. `np-generate-code` (:8437) emits chunked byte items `(byte . n)`, `(word . n)`, and `(asm ,op ,item ,offset)` placeholders plus a `funcrel*` relocation list (`make-funcrel` :8367).
2. `c-mkcode` (`s/compile.ss:86`) walks the code list, materializes bytes (`$set-code-byte!/word!/long!/quad!`), and turns `asm` items into relocation records (`reloc-abs`, `reloc-rel`, `reloc-x86_64-jump/call/popcount/fpround`, …) at :137–:220.
3. `s/reloc.ss` builds the relocation table via C entry points (`s_make_reloc_table`, `s_set_reloc`, `link_code_object`).
4. `c/prim5.c` (`s_set_code_byte/...`, `s_set_reloc`, `s_make_reloc_table`) and `c/prim.c` (`link_code_object`) patch and link the final code object.

## The pb (portable bytecode) backend

Same architecture, one indirection: `s/pb.ss` emits fixed-width 32-bit bytecode instructions whose opcodes are `pb-*` enumeration constants (`s/cmacros.ss:3314`), generated from the same `(constant …)` source as the C side (`c/pb.h`, `c/pb.c`), so the two never drift. Execution is either the `S_pb_interp` interpreter or C chunks translated from hot bytecode segments (`s/pbchunk.ss`).

## Reading order

1. This file.
2. `../03-backend/flags-truth-tables.md` — the single source of truth for any flags-based reasoning.
3. `../04-verification/reachability-rule.md` — before writing or reviewing any codegen test.
4. `s/cpnanopass.ss` `$np-compile` sequence (:11146) with this map beside you.
5. `s/x86_64.ss` sections 1→2→3, one instruction family at a time.
6. `s/compile.ss` `c-mkcode` + `s/reloc.ss` for the last mile.
