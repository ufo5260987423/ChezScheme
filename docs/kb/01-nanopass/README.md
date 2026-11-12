# Nanopass Framework

Articles:

- [`define-language-and-define-pass.md`](define-language-and-define-pass.md) — the framework implementation (`nanopass/nanopass/language.ss`, `nanopass/nanopass/pass.ss`): terminals, productions, automatic traversal, multiple return values, `with-output-language`, and how the build wires it into the compiler.
- [`the-l1-l16-ladder.md`](the-l1-l16-ladder.md) — `s/np-languages.ss`: how each pass extends its input language, and how to read a production diff between two language levels.

Anchor map (already surveyed): see `../00-overview/compilation-pipeline.md` for the pass table with line numbers; verify anchors against your checkout before citing them.
