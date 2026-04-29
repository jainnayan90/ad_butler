# Scratchpad: audit-2026-04-29-perf-arch

## Key Decisions

- **P1-T1**: Use `Decimal.new(score)` when building entries for `insert_all` — bypasses Ecto type casting; bare integer would cause type mismatch on decimal column
- **P1-T2**: MapSet is a perf optimization only; DB partial unique index `findings_ad_id_kind_unresolved_index` remains the authoritative dedup guard
- **P2-T1**: Removing `belongs_to` removes the Ecto virtual association field (`.ad`, `.ad_account`) but keeps the FK field (`.ad_id`, `.ad_account_id`) — must add explicit `field :ad_id, :binary_id` replacements
- **P2-T2**: `list_ad_account_ids_for_mc_ids/1` is a SELECT of IDs only (not full structs) — more efficient than mapping over `list_ad_accounts_by_mc_ids/1`
- **P2-T3**: Callers pass full `%MetaConnection{}` struct just to extract `.id` — the fix is to accept `meta_connection_id` binary; update callers to pass `connection.id`

## Dead Ends

(none yet)
