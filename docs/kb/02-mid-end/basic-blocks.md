# Basic Blocks (`np-expose-basic-blocks` and the Block Graph)

How structured L14 tails/preds/effects become a mutable graph of block records, and the utility passes that annotate it between flattening and register allocation. Driver order is `np-after-calling-conventions` (`s/cpnanopass.ss:11122-11144`); anchors verified at commit `a8e3eb6d`.

## The block record family

Base record `block` — `s/np-languages.ss:1118` — with mutable fields `label`, `effect*`, `src*`, `pseudo-src`, `in-link*`, `flags`, `fp-offset`, `live-in`, `depth`, `loop-headers`, `index`, `weight`. `flags` is a bitfield (`define-flag-field`, `:209`; block flags at `:1138`):

| Flag | Meaning |
|---|---|
| `pariah` | unreachable on normal paths — error/slow paths; see below |
| `seen` / `finished` | transient DFS marks used by the graph walkers |
| `return-point` | block is, or leads to, a call return point |
| `repeater` | empty goto folded into its successor (repeater removal) |
| `loop-header` | header of a natural loop |

Subtypes (`s/cpnanopass.ss`):

| Record | Line | Extra fields | Role |
|---|---|---|---|
| `goto-block` | :7145 | `next` | unconditional edge |
| `if-block` | :7157 | `pred`, `true`, `false`, `live-out` | conditional two-way edge |
| `newframe-block` | :7171 | `info`, `next`, `rp*`, `rp`, `live-rp`, `live-call`, `live-out` | call region: outgoing edge + return-point links |
| `joto-block` | :7188 | `nfv*`, `next` | local jump with non-frame vars |
| `tail-block` | :7198 | `tail`, `exit` | block ending in `jump`/`asm-return`/`asm-c-return` |
| `start-block` | (profiling module, `:7578`) | — | profiling entry/exit instrumentation |

L15a exposes `(block entry-block)` as terminals and the lambda shape `(lambda info max-fv (local* ...) (entry-block* ...) (block* ...))` (`s/np-languages.ss:1182-1187`).

## `np-expose-basic-blocks` (:7253, L14→L15a)

Flattens each lambda body into blocks. The workhorse is the nested pass `build-graph` (`:7273`) — note the framework feature in action: `-> * (block block*)` returns the entry block *and* the accumulated block list.

- Effects accumulate into the current block via `add-instr!` (`:7255-7257`), each decorated with a fresh `live-info` for register allocation.
- Edges are wired through `local-label-block` indirection: `add-label-link!` (`:7259-7264`) either links immediately or queues a thunk for not-yet-created targets; `resolve-waiting-links!` (`:7266-7271`) drains the queue when the target materializes.
- `(if p tl1 tl2)` splits into an `if-block` whose arms are the recursively built tails (`:7307-7309`); `new-frame` becomes a `newframe-block` with each return-point label linked to its continuation block (`:7343-7353`); `return-point` effects set the block's `return-point` flag (`:7360-7363`); `(pariah)` sets the `pariah` flag (`:7371-7372`) — those originate from cpprim's slow paths (see `primitive-expansion.md`).
- Unreachable blocks produced along the way are discarded after the build (`:7455-7458`).

## Graph utilities (in driver order)

**`np-remove-repeater-blocks!`** (`:7491`). Path-compresses chains of empty `goto-block`s: `path-compress!` (`:7493-7502`) marks each emptied goto as a `repeater` pointing at the final target, then every edge field (`resolve!`, `:7512-7532`) and entry label is short-circuited. Repeater blocks are dropped from the list unless they are their own target (a tight infinite loop, `:7540-7542`). Runs again after register allocation as `np-remove-repeater-blocks-again!` (`:11002`, L16), when spill code may have created new chains.

**`np-add-block-source!`** (`:7466`). Only under block profiling with source info (`:11128-11131`); attaches source records to blocks.

**`np-propagate-pariahty!`** (`:7544`). The name is Chez's own. Strategy, verbatim from `:7568-7571`: *"optimistically assume all blocks are pariahs, then un-pariah anything reachable from the entry block without going through a known pariah block."* A "pariah" block is an outcast — code reachable only through error traps, type-check failures, or `(pariah)`-marked slow paths. Pariah status is not an optimization license to delete anything (the blocks are still reachable from return points); it is a *weight* signal: pariah blocks get weight 0 in `np-weight-references!` (`:8287-8289`), so their code is laid out out of the way and their register pressure is discounted.

**`np-insert-profiling`** (module `:7575`, pass `:8068`). Only when `($compile-profile)` is `'source`, or `'block` with sfd (`:11133-11137`). Adds `start`/`exit` blocks and per-block link records (`:8068-8074`) so runtime profile data can be attributed to blocks. That profile data later feeds `np-weight-references!`.

**`np-add-in-links!`** (`:8161`). Builds predecessor lists: for every edge (`goto`, `if` both ways, `newframe` next/rps, `joto`) the target's `in-link*` gets the source block. Consumed by live analysis and loop depth.

**`np-compute-loop-depth!`** (`:8183`). A DFS marks loop headers when it re-encounters a `seen` block (`:8194-8195`); a second pass computes each block's `loop-headers` set as a bitmap over the header vector (`:8214-8257`), then depth by max over enclosing headers plus one for headers themselves (`:8261-8273`). The traversal order of the two loops must match — the code comments call this out (`:8243`, `:8247`, `:8258-8259`).

**`np-weight-references!`** (`:8280`). Combines the previous two annotations into per-block weights: with profile data, normalize block counts; without, `4^min(depth,5)`; pariah blocks get 0 (`:8285-8290`). The weight then accumulates into every `uvar` touched by the block (`process-var`, `:8295-8298`) — the `uvar-ref-weight` / `uvar-save-weight` that drive spill decisions in `np-allocate-registers` (`:10886`).

## Downstream

The annotated graph is what `np-allocate-registers` consumes: live analysis fills `block-live-in` (`np-languages.ss:1143`), conflicts are built per block, `select-instructions!` (`:10203`) lowers each L15c block to L15d `asm` forms, and `np-optimize-block-order!` (`:11058`) uses the weights again for code layout before `np-generate-code` (`:8437`) emits chunks.

## Verification hooks

- `(#%$np-tracer 'np-expose-basic-blocks)` prints the unparsed L15a graph — the quickest way to see what a construct became (e.g. an `if` with a pariah arm shows up as an `if-block` with one arm's blocks flagged).
- The `#;(p-dot-graph ...)` / `#;(p-graph ...)` helpers at `:8275-8276` dump a Graphviz view when enabled.
