# Mid-End Passes

Articles:

- [`closure-conversion.md`](closure-conversion.md) — `np-convert-closures` and friends (`s/cpnanopass.ss:1418-2092`): free-variable annotation, SCC identification, well-known lifting, and closure representation selection.
- [`primitive-expansion.md`](primitive-expansion.md) — `$np-expand-primitives` in `s/cpprim.ss`: how safe operations become nested type checks around unsafe inlines, and why that shapes what the backend can match. Feeds directly into recipe S-4 in `../04-verification/shape-forcing-recipes.md`.
- [`calling-conventions.md`](calling-conventions.md) — `np-impose-calling-conventions` (`s/cpnanopass.ss:4282`): frame layout, argument/result movement, case-lambda dispatch (L12.5→L13).
- [`basic-blocks.md`](basic-blocks.md) — `np-expose-basic-blocks` (`s/cpnanopass.ss:7253`) and the block-graph utilities: repeater removal, pariah propagation, profiling, in-links, loop depth, reference weights.
- [`cp0-shape-eating.md`](cp0-shape-eating.md) — the mid-end rewrites that mask backend reachability (see `../04-verification/reachability-rule.md`, "masked reachability"), measured on the ta6le build. This is the article that would have prevented the select NaN incident.

Anchor map (already surveyed): see `../00-overview/compilation-pipeline.md` for the pass table with line numbers; verify anchors against your checkout before citing them.
