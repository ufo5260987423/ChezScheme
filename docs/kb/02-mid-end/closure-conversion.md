# Closure Conversion

The six passes that turn `letrec`-bound lambdas into closure objects and labeled code, `s/cpnanopass.ss:1418-2092`. Pipeline position: after lexical restructuring (`np-name-anonymous-lambda`, :1405, →L5) and before `np-simplify-if` (:2567). Language levels involved: L5 → L6 → L7 (see `../01-nanopass/the-l1-l16-ladder.md`).

## The chain

```
np-convert-closures        :1418  L5 → L6
np-optimize-direct-call    :1498  L6 → L6
np-identify-scc            :1557  L6 → L6
np-lift-well-known-closures :1632 L6 → L6   (only when ($lift-closures), :11168)
np-expand/optimize-closures :2092 L6 → L7   (when ($optimize-closures), :11171)
np-expand-closures          :2011 L6 → L7   (otherwise)
```

## `np-convert-closures` (:1418, L5→L6)

Annotates every lambda with its free variables; introduces the `closures` form and the `mcp` (maybe closure parent) clause field that L6 adds (`s/np-languages.ss:545-555`).

- A per-clause `clinfo` record (`:1420-1424`) accumulates the free variable list and a bitmask of referenced slots while the clause body is traversed; `record-ref!` (`:1440-1448`) records each free reference, both for the current closure and (recursively) for outer ones.
- Free variables are assigned closure-slot indices through `var-index` under `with-offsets` (`:1425-1439`) — the same `var-index` mechanism register allocation later reuses.
- Output per clause: `(clause (x* ...) mcp interface body)` where `mcp` is `#f` or a `cpvar` holding the parent closure when the clause has free variables (`:1486-1493`). Each `letrec` of lambdas becomes `(closures ([x* (fv** ...) le*] ...) body)` (`:1451-1458`).
- Well-known status: a lambda bound where all references are known gets marked in its `info-lambda` (the `well-known?` field, mutable per `s/np-info.ss`), which the later passes exploit.

## `np-optimize-direct-call` (:1498, L6→L6)

When the operator of a call is statically known to be a particular case-lambda binding, replace the general "call through closure" with a direct jump to the matching clause's label. `find-matching-clause` (`:1500-1515`) resolves the arity against the callee's interface list (fixed or variable) and picks the clause's `dcl`; failure keeps the general call. Result: a `direct-call-label` reference instead of an indirect closure call — cheaper, and it feeds the code layout (only referenced labels survive later pruning).

## `np-identify-scc` (:1557, L6→L6)

Runs Tarjan's algorithm (`compute-sccs`, `:1573-1602`) over the bindings of each `closures` form, building dependency links from each binding to the bindings of its free variables (`:1606-1618`). The re-sorted output is one `closures` form **per strongly connected component**, ordered so dependencies come first (`:1624-1628`; the ordering contract is stated at `:1559-1562`). Why it matters: bindings in separate SCCs don't need mutually recursive closure allocation, and singleton/well-known analysis can treat each SCC independently. This is the same SCC machinery the front end already used in `cpletrec`.

## `np-lift-well-known-closures` (:1632, L6→L6)

"Lifts all internal well-known closures to an outermost lambda body with a lift barrier" (comment at `:1631`). A well-known closure referenced only from within the same lambda body can be moved out of its `closures` form into the enclosing body — it no longer needs a closure environment of its own; free variables just become locals of the enclosing lambda. `var-index` values `'lifted`/`'loop` mark lifted variables (`:1637`, `:1657`); `outer?` (`:1648-1655`) decides lift eligibility by index comparison. Gated by `($lift-closures)` in the driver (`:11168-11170`).

## `np-expand-closures` (:2011) vs `np-expand/optimize-closures` (:2092), L6→L7

Both erase the `closures` form and produce the top-level `(labels ([l* le*] ...) l)` `Program` shape that L7 introduces (`s/np-languages.ss:574-576`), hoisting every closure's code to a label. Both sort the label bindings by `info-lambda` seqno (`sort-bindings`, `:1993-2009`) so the optimized and unoptimized paths produce the same code layout — a deliberate experiment-control measure (comment `:1994-2000`). Both record the final free-var list and representation on the `info-lambda` (`:2065-2066`).

**`np-expand-closures`** (plain, used when `($optimize-closures)` is #f): allocates a full closure object per binding — `%constant-alloc type-closure` sized by free-var count (`:2044-2045`), stores the code label at `closure-code-disp` (`:2047`), then initializes every data slot (`create-inits`, `:2052-2062`). Free-variable references inside the body are rewritten through `uvar-location` set up by `with-locations` (`:2028-2037`) to `mref` off the `mcp`. Also handles `(fcallable info)` by allocating a label and yielding a `label-ref` (`:2081-2085`).

**`np-expand/optimize-closures`** (default): chooses a *representation per closure* instead of always allocating:

| Representation | When | Code shape |
|---|---|---|
| `constant` | no free vars, known code | no allocation at all |
| `singleton` | one free var | reference the parent directly (`with-frob-location` on the single fv, `:2377`) |
| `pair` | two free vars, well-known | `cons` of the two fvs (`:2365-2367`) |
| `vector` | more fvs, well-known | `vector` of the fvs (`:2368-2370`) |
| `borrowed` | shares an existing closure | — |
| `closure` | otherwise | full allocation as in the plain pass (`:2373-2377`) |

The representation vocabulary above (`constant`/`singleton`/`pair`/ `vector`/`borrowed`/`closure`, well-known or not) is exercised by the static-counting dispatch (`:2115-2143`); `create-bindings`/ `create-inits` (`:2340-2377`) emit the corresponding code. Static counts by representation and well-knownness accumulate when `$track-static-closure-counts` is on. Free-variable references go through *frob* locations — an extra indirection layer (`frob-expr`, `:2326-2332`) so that e.g. a `singleton` closure's single free variable can be reached through the parent without a real slot.

## Output contract (L7)

After this chain: no `closures`, no `letrec-of-lambdas` — just a `labels` program of `case-lambda`s whose bodies use `inline` primitives, `label-ref`s, and `mref` lvalues; every free-variable access is either a local or an explicit memory reference off the `mcp`. This is the input `$np-expand-primitives` (`s/cpprim.ss:106`) assumes.
