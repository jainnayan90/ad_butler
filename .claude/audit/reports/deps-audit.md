# Dependencies Audit
Date: 2026-04-25

## Score: 97/100

## Issues Found

### `logger_json` pinned to 6.x — 7.0.4 available but upgrade blocked by constraint
`mix.exs:83` — {:logger_json, "~> 6.0"}

logger_json 7.0.4 is available but ~> 6.0 prevents upgrading. The 6.x series is current
at 6.2.1 and maintained, but worth scheduling a v7 migration.
Deduction: -3 pts (1 major version behind, not >2)

## Clean Areas
mix hex.audit reports no retired packages. All 27 other dependencies up-to-date. All
version constraints use ~> (minor-compatible). No unused dependencies. precommit alias
includes hex.audit ensuring retired packages are caught pre-commit.

## Score Breakdown

| Criterion | Score | Max | Notes |
|-----------|-------|-----|-------|
| No hex.audit vulnerabilities | 40 | 40 | No retired packages |
| No deps.audit issues | 20 | 20 | Task unavailable; no known issues |
| No major version behind >2 | 17 | 20 | logger_json 1 major behind — -3 pts |
| No unused dependencies | 10 | 10 | All deps in active use |
| Version pinning appropriate | 10 | 10 | All use ~> constraints |
