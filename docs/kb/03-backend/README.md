# Backend: Instruction Set, Assembler Emission, Code Generation

Articles on the machine layer: descriptions, selection, assembly, flags, generation, and the portable backend. Anchors verified against the current `x86-64-select` checkout (see `../00-overview/compilation-pipeline.md`).

## Present

- [`flags-truth-tables.md`](flags-truth-tables.md) — **the authoritative flags reference (T-1/T-2) and derivation rules R-1…R-4. Every flags-based sequence must be derivable here.**
- [`machine-def-files.md`](machine-def-files.md) — the `.def` constant files, `s/machine.zuo` synthesis from machine-type strings (`ta6le`…), and the capability-bit gating pattern (`setcc-instruction`; checklist section C).
- [`x86_64-backend.md`](x86_64-backend.md) — the three sections of `s/x86_64.ss` (registers, instruction selection, `asm-module`), the register table incl. `%tc`/`%sfp`/`ap` and C ABI aliases, and the full contract cards for the `isel`/`fpsel` select family.
- [`define-op-and-encoding.md`](define-op-and-encoding.md) — `define-op` (`s/x86_64.ss:1216`), `emit` (:1244), `emit-code` (:1913), `emit-literal-code` (:1926), `asm-size` (:2117), with the `sse.roundsd` encoding (:1402-1422) as worked example.
- [`instruction-selection.md`](instruction-selection.md) — `define-instruction` (`s/cpnanopass.ss:10013`), `select-instructions!` (:10203), `coerce-opnd` operand constraints, and the `make-unspillable` discipline behind RULE-UNSPILL (commit `5b6227fb`).
- [`code-generation-and-relocation.md`](code-generation-and-relocation.md) — `np-generate-code` (:8437) two-pass chunk emission, `c-mkcode` (`s/compile.ss:86`), the `s/reloc.ss` bridge, and the C side (`c/prim5.c` `s_set_reloc`, `c/prim.c` `link_code_object`).
- [`pb-backend.md`](pb-backend.md) — `s/pb.ss`, `pb-*` opcode enums (`s/cmacros.ss:3218`), the `c/pb.h`/`c/pb.c` interpreter, and `s/pbchunk.ss` C-chunk translation, with a pb-vs-native comparison.
