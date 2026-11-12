# The Reachability Rule

*[RULE-REACH] A value test proves nothing about generated code unless it also proves the intended code path executed.*

## Statement

Value tests ("the program returns the right answer") and path tests ("the compiler emitted the sequence under test") are different claims. A mat that only checks values can pass while the feature it targets is never exercised — because an earlier pass silently rewrites the program into a shape that bypasses the feature.

## Why this rule exists: the select NaN incident

The branchless-select PR added a setcc-based boolean specialization (`asm-fpsel-bool`) and value mats for boolean selects "in either arm order". All mats passed. Yet the *reverse* arm order never executed the new sequence at all: cp0 normalizes `(if (fl< x y) #f #t)` before the backend ever sees it, so the reverse-order mats exercised the plain branchy codegen and passed vacuously. The sequence contained a real NaN bug that every mat green-lit. Months later it was reached via an IR shape cp0 could not see through, and miscompiled.

The general pattern, worth a name:

> **Masked reachability.** A defect lives on a path that mid-end > normalization currently masks. Surface tests stay green forever. > The bug surfaces only when code reaches the emitter through a > non-canonical shape (macro expansion, `eval` with a custom > `run-cp0`, compiler-internal sources, a future cp0 change).

## What every codegen mat must carry

1. **Path evidence** — one of:
   - a `select-instructions` / compiler trace showing the target instruction or emitter fired (the cheapest proof);
   - an instrumented compiler run (temporary probe in the emitter, rebuild, observe) — heavyweight, but conclusive;
   - a shape argument: the mat's source is constructed so that no earlier pass *can* rewrite it (see `../shape-forcing-recipes.md`), plus a trace spot-check at authoring time.
2. **Both canonical and adversarial shapes** — the canonical shape *and* at least one shape that defeats each relevant mid-end normalization (constant folding, cp0 boolean canonicalization, type-driven inlining).

## Practical check at authoring time

```
Does the test pass with the target code deleted/disabled?
  → yes  = the test is vacuous; rewrite it with a forced shape.
  → no   = the test actually covers the feature.
```

This one question would have caught every masked-reachability bug found so far in the select work.
