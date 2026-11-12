# Chez Scheme Backend Knowledge Base

A knowledge base about how the Chez Scheme compiler turns source code into machine code: the instruction sets, the assembler emitters, and the nanopass optimizations in between.

This is not passive documentation. It is organized as a **constraint system** so that the bug classes seen in the `sel-stage3` select work (hardcoded semantic shortcuts in emitters, masked by mid-end normalization, invisible to value tests) become harder to reintroduce.

## The four constraint layers

| Layer | What it constrains | Where |
|---|---|---|
| 1. Design contracts | Assumptions at authoring time: every backend specialization carries a contract card with producers, reachable shapes, and invariants | contract cards inside `03-backend/` articles |
| 2. Flag truth tables | The correctness of reasoning itself: one authoritative derivation source for every setcc/cmov sequence | `03-backend/flags-truth-tables.md` |
| 3. Verification methodology | Test effectiveness: value tests alone are insufficient; every codegen mat needs path evidence | `04-verification/` |
| 4. Executable checks | Regression, in CI: exhaustive semantics cross-checkers derived from the truth tables | `tools/` |

Rules written in *italics* prefixed with `[RULE]` are normative: new backend work is expected to comply and reviewers are expected to enforce.

## Layout

- `00-overview/` — the compilation pipeline panorama and the glossary. Read `compilation-pipeline.md` first.
- `01-nanopass/` — the nanopass framework (`define-language`, `define-pass`) and the L1–L16 language ladder.
- `02-mid-end/` — the mid-end passes: closure conversion, primitive expansion, calling conventions, basic blocks.
- `03-backend/` — machine descriptions, instruction selection, the x86_64 assembler, flag semantics, code generation, relocation, and the pb backend.
- `04-verification/` — the reachability rule, shape-forcing recipes, and review checklists.
- `05-case-studies/` — post-mortems, each following the template: contract violation → truth-table derivation → why surface tests stayed green → forced-shape reproduction → fix → what was distilled into contracts/checklists/tools.
- `tools/` — runnable verification scripts.

## Code anchors

Articles cite code as `file:line`. Line numbers track the `sel-stage3` branch (cpnanopass.ss is ~11k lines and fairly stable), but always verify against your checkout.
