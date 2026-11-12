# Case Studies

Bug post-mortems follow the template:

1. **Symptom** — minimal reproduction.
2. **Contract violation** — which invariant was broken, where.
3. **Truth-table resolution** — the derivation that settles it.
4. **Why surface tests stayed green** — the masking mechanism.
5. **Forced-shape reproduction** — which recipes exposed it.
6. **Fix** — and its verification.
7. **Distillation** — what it added to contracts / checklists / tools.

Design case studies (optimizations authored with the KB rules already in mind) adapt the template to: **Motivation → Design → Where it lives (code anchors) → Contract/truth-table notes → Verification → Relationship to KB rules**. Anchors are verified against the `kb-backend` workspace where possible; branch-only code is marked "as of branch X" with the commit and in-branch line numbers.

## Present

- [`select-nan-reverse-bool.md`](select-nan-reverse-bool.md) — the reverse-order `asm-fpsel-bool` NaN miscompile; the incident that established this knowledge base's verification layer.
- [`cmov-fxminmax.md`](cmov-fxminmax.md) — branchless `fxmin`/`fxmax` via `cmp + cmovcc`; aliasing-case dispatch and the modrm operand order; notable for its verification gap (no mats, no path evidence).
- [`roundsd-flround.md`](roundsd-flround.md) — the `roundsd` family (`flround`/`flfloor`/`flceiling`/`fltruncate`) traced from two local branches through `x86-64-level` capability gating to the landed form; includes a honestly-reported 26% regression.
- [`magic-divide.md`](magic-divide.md) — fixnum division strength reduction by magic-number mul-high; the Granlund–Montgomery side condition, the compile-time verifier that declines to `idiv`, and three pre-landing bugs found under `gdb`/`setarch -R`.
