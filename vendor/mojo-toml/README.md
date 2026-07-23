# mojo-toml provenance

This directory vendors the parser-only portion of
[`mojo-toml`](https://github.com/DataBooth/mojo-toml) v0.9.1 at release commit
`346b7ad723c034f7696723f4846203d47ef86951`. Upstream `main` commit
`c3262adea2d314748716991f99d0276f4a0b5e79` had byte-identical lexer, parser,
initializer, and Apache-2.0 license bytes when the dependency was adopted.

Retained files:

- `toml/lexer.mojo`
- `toml/parser.mojo`
- `toml/__init__.mojo`, reduced to parser exports
- `LICENSE`

Local compatibility and hardening changes are limited to:

- Mojo 1.0.0b2 syntax (`fn` to `def`, and `std.math` imports)
- parser-only package exports
- strict numeric token and signed 64-bit integer validation
- parser depth, node, and table-update budgets
- duplicate table, key, and inline-table rejection
- TOML 1.0 escape handling and positioned lexer failures
- terminated, control-free strings and Unicode escape decoding
- pre-lexer scalar, structural-node, and depth budgets

The production build precompiles this source locally. It does not download
dependencies. `CHECKSUMS.json` pins the authorized commits and upstream bytes,
then records every retained source digest after the local patches. The harness
recomputes those local digests.
