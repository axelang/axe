This directory contains the self-hosted version of the Axe compiler, written in Axe itself.

## Status: WIP

### TODO

#### Bugfixes

- [x] Fix `[]` syntax with non-primitive types
- [ ] "Must initialize" constraint for primitive type inits.

#### Overarching

- [x] **lexer.axe** - Lexical Analysis and Tokenization
- [x] **parser.axe** - Parse tokens into an AST
- [x] **builds.axe** - Build orchestration
- [x] **structs.axe** - Structs and enums
- [x] **renderer.axe** - Renderer for AST
- [x] **imports.axe** - Module import resolution
- [x] Derive module names from file path (and directory) in `builds.axe` to match D compiler semantics
- [x] Implement richer import semantics and name rewriting (prefixed calls, selective imports, visibility) in `imports.axe`
