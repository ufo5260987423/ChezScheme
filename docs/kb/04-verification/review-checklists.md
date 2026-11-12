# Review Checklists

Normative checklists for reviewing backend/compiler work. Rules prefixed `[RULE-…]` are enforced on the `sel-stage3`-lineage PRs; each rule points at the article that justifies it.

## A. Backend specialization (new/changed emitter or `define-instruction` clause)

- [ ] **[RULE-TRUTH]** Every flags-consuming sequence is derived from `../../03-backend/flags-truth-tables.md` (T-1/T-2 + derivation rules R-1…R-4). The PR description shows the derivation or cites the table cells.
- [ ] **[RULE-SYM]** If the clause is reachable with swapped arm/operand orders (condition inversion), the shortcut is checked in **both** orders per R-2. If one order is not supported, the clause declines it explicitly (guard/comment), never silently.
- [ ] **[RULE-TRUTH-NA]** FP sequences handle the unordered column: for `ucomisd`-driven `e`/`ne` an explicit `jp` escape is present, the skip offset is computed from emitted code (not a hand count), and its target is verified for **both** arm orders. `a/ae/b/be` need no escape (T-2); say so rather than emitting one "just in case".
- [ ] **[RULE-PRODUCERS]** The PR lists the passes that can produce the new instruction/emitter call (e.g. `rhs-inline`, `select-if`, `select-tail`, cpprim inlining) and argues which operand/flag shapes each can deliver — or adds a `safe-assert`/guard.
- [ ] **[RULE-ALIAS]** Destination/operand aliasing is handled at emit time by dispatching on the actual register relationships (`(equal? dest u)`, `(equal? dest v)`), not by a single preset sequence — the allocator may coalesce any pair (see `asm-fpsel-regs`, `s/x86_64.ss:2513`; the 2025 bootstrap bignum miscompile came from a preset clobbering a coalesced operand).
- [ ] **[RULE-UNSPILL]** Any new scratch introduced in an instruction clause is assigned by a plain `set!` before the self-referential `asm` (unspillable-conflict walk requirement; see the `(z mem)` clause history, commit 5b6227fb).

## B. Tests accompanying a backend specialization

- [ ] **[RULE-REACH]** Every mat carries path evidence per `../reachability-rule.md`: a trace citation, a shape-forcing recipe (`../shape-forcing-recipes.md`), or an authoring-time trace check. The vacuity question is answered: "does this mat fail if the target code is removed?"
- [ ] **[RULE-EDGE]** Boundary inputs are enumerated from the truth table: for FP — both operand positions NaN, equal operands, ±0.0, infinities where meaningful; for integers — extremes, sign boundaries, mixed-sign comparisons.
- [ ] **[RULE-DIFF]** Where an independent reference exists, a differential test compares against it (recipe S-3 gives a branch-forced reference for predicates).

## C. Interface / layering changes

- [ ] The change does not push representation knowledge up a layer (mflatt's criterion from PR #1097 review): the *interface* sees machine words and operand shapes; `#t/#f` encodings stay inside the specialization.
- [ ] Architecture gating uses the `.def` capability-bit pattern (`setcc-instruction` in `s/a6.def`, `default.def #f`) rather than `architecture` checks scattered in passes.
- [ ] A new IR instruction updates: `np-languages.ss` production, `pred->…`/conversion tables, every backend's `define-instruction` (or an explicit "declined" path), and the mats.

## D. Process

- [ ] Commit messages distinguish *verified* claims (bootstrap rounds, mats at o=0/o=3, traces) from *inferred* ones, and say which.
- [ ] A fix for a masked-reachability bug adds the adversarial-shape mat **first** (fails before the fix, passes after), like `mats/fx.ms` "cover NaN in both arm orders".
