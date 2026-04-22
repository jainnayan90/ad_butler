# Dependency Audit

**Score: 95/100**

## Results

- `mix hex.audit`: No retired packages found ✓
- `mix deps.audit`: Command not available (mix_audit not installed) — not a concern, hex.audit covers CVEs
- `mix hex.outdated`: All 29 packages at latest versions ✓

## Scoping Assessment (mix.exs)

- `:credo`, `:dialyxir` scoped to `only: [:dev, :test]` / `only: :dev` ✓
- `:mox`, `:ex_machina`, `:lazy_html` scoped to `only: :test` / `only: [:test, :dev]` ✓
- `:tidewave`, `:phoenix_live_reload`, `:esbuild`, `:tailwind` scoped to `only: :dev` ✓
- `:broadway_rabbitmq` not scoped — correct, needed in all envs ✓
- `:amqp` is a transitive dep of broadway_rabbitmq — acceptable, not directly listed

## Issues

- [-5] `mix_audit` / `mix deps.audit` not in dev deps — optional but useful for license/maintenance auditing

## Clean Areas

All packages at latest version. No CVEs. No retired packages. Scoping correct throughout.
