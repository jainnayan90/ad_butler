# AdButler — Claude Code Principles

## Documentation

Every module and every non-private function must have documentation:

- **`@moduledoc`** on every module — describe what the module does, its role in the
  system, and any key design constraints or invariants (e.g. security scope, retry
  behaviour, naming conventions).
- **`@doc`** on every public `def` — describe parameters, return values, and any
  non-obvious edge cases. One-line docs are fine for simple getters/upserts; use a
  multi-line doc for functions with meaningful side-effects or branching behaviour.
- **Exceptions** — OTP callbacks that implement a `@behaviour` and are tagged with
  `@impl true` do not need `@doc` (the behaviour contract documents them). Use
  `@doc false` only for functions that are technically public but not part of the
  intended API (e.g. Plug `init/1`/`call/2` boilerplate).
- **Test modules** — skip; test files are excluded from this rule.
- When adding a new module or public function, add the doc in the same commit — do
  not leave it as a follow-up.
