# Scratchpad: week-2-auditor-post-review

## Decisions

- B1 context extraction: Three private Repo calls become `unsafe_*` functions in `AdButler.Ads`, matching the existing pattern for unscoped internal queries.
- B2 error propagation: `run_heuristics` becomes a reduce_while returning `{:ok, [kinds]} | {:error, reason}`. `audit_account` uses `with` to chain heuristic errors with health-score errors.
- W2 N+1 fix: `unsafe_list_30d_baselines/1([ad_ids])` preloads all baselines in one query before the reduce. `check_cpa_explosion` receives the map directly instead of calling the DB per-ad.
- W5 double query: Guard `paginate_findings` in `handle_params` with `if connected?(socket)`.
- S1 shared helpers: New `AdButlerWeb.FindingHelpers` module imported explicitly in both LiveViews.

## Dead Ends

- **B6 error-flash test**: `acknowledge_changeset` uses `change/2` — no constraint registered, so `Repo.update/2` never returns `{:error, _}` for FK violations. Deleting the row causes `get_finding!` to raise `Ecto.NoResultsError`, which propagates as a linked-process EXIT signal, not a local raise. `assert_raise` and `catch_exit` both fail. Testing this path requires adding an Analytics behaviour + Mox mock. Skipped.
- **`Oban.insert_all/1` return**: Confirmed it returns a list of `{:ok, job} | {:error, changeset}` per job (not a single tagged tuple). Handler checks `Enum.filter(results, &match?({:error, _}, &1))`.

## Risks / Dead Ends (original)

- `Oban.insert_all/1` return shape in Oban 2.18: returns `{:ok, [%Oban.Job{}]}` per docs, but verify conflict/error path.
- `unsafe_list_30d_baselines` UUID encoding: `ad_insights_30d.ad_id` is binary UUID. The `Ecto.UUID.dump!/1` call is needed for the `in` clause. Map keys must be string UUIDs matching `Ad.id`.
- P2-T1 is the largest change — run worker tests immediately after before proceeding to Phase 3.
