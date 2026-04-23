---
module: "AdButler.Ads"
date: "2026-04-22"
problem_type: validation_logic
component: ecto_changeset
symptoms:
  - "bulk_validate drops ALL rows even when data looks valid"
  - "Orphan pipeline test fails: Repo.aggregate(Ad, :count) == 0 instead of 1"
  - "Logger.warning bulk_validate: dropped invalid rows count=2 for valid ads"
root_cause: "bulk_validate/2 ran changeset validation before ad_account_id was injected into entries. The changeset's @required list includes :ad_account_id, so every row failed valid? even with correct data."
severity: high
tags: [ecto, changeset, bulk-insert, validation, foreign-key, injection-order]
---

# Ecto: bulk_validate Must Run AFTER Foreign Key Injection

## Symptoms

Added a `bulk_validate/2` helper that runs each attrs map through
`schema_mod.changeset(struct(schema_mod), attrs).valid?`. Placed it at
the top of `bulk_upsert_ads/2`:

```elixir
def bulk_upsert_ads(%AdAccount{} = ad_account, attrs_list) do
  now = DateTime.utc_now()
  attrs_list = bulk_validate(attrs_list, Ad)   # ← called here

  entries =
    Enum.map(attrs_list, fn attrs ->
      attrs
      |> Map.put(:ad_account_id, ad_account.id)   # ← FK added here
      |> Map.put(:inserted_at, now)
      ...
    end)
```

Result: all rows silently dropped. `Repo.aggregate(Ad, :count) == 0`.
Pipeline test for orphan filtering failed because even the "good" ad was dropped.

## Investigation

1. `Ad.__schema__(:fields)` includes `@required [:ad_account_id, :ad_set_id, :meta_id, :name, :status]`
2. At the point `bulk_validate` ran, `attrs` only had `{meta_id, name, status, ad_set_id, raw_jsonb}` —
   no `ad_account_id` yet
3. `Ad.changeset(struct(Ad), attrs).valid?` → `false` for EVERY row because `ad_account_id` nil
4. All rows moved to `invalid` list, logged as dropped, nothing inserted

## Root Cause

The FK (`ad_account_id`) is set inside `bulk_upsert_*` by the caller pattern
`Map.put(:ad_account_id, ad_account.id)`. Validation was placed before this step,
meaning the changeset saw nil for a required field on every row.

The pattern is: **build complete entries first, validate second, insert third.**

## Solution

Move `bulk_validate` to run on the fully-built `entries` list (after FK injection):

```elixir
def bulk_upsert_ads(%AdAccount{} = ad_account, attrs_list) do
  now = DateTime.utc_now()

  entries =
    Enum.map(attrs_list, fn attrs ->
      attrs
      |> Map.put(:ad_account_id, ad_account.id)   # ← FK injected first
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)

  entries = bulk_validate(entries, Ad)             # ← validation after FK

  Repo.insert_all(Ad, entries, ...)
end
```

Also: `bulk_validate` should prune unknown keys from valid entries using
`Map.take(entry, schema_mod.__schema__(:fields))` to prevent unknown-field
raises if future build functions add extra keys.

### Files Changed

- `lib/ad_butler/ads.ex` — Moved `bulk_validate` call to after entries built in all three `bulk_upsert_*` functions

## Prevention

- [ ] In `bulk_upsert_*` functions, always build the complete entry map (including all FKs) BEFORE running changeset validation
- [ ] Rule of thumb: `validate → insert` ordering only works when the data being validated is complete
- [ ] When `bulk_validate` drops all rows silently, first check: are all required fields present at validation time?
- [ ] After adding `bulk_validate`, add a test where valid data IS upserted (not just invalid data dropped) to catch false-negative validation
- [ ] Use `schema_mod.__schema__(:fields)` to prune unknown keys from entries before `Repo.insert_all` to prevent Postgrex raises on future schema drift

## Related

- `nullable-fk-references-not-null-false-20260421.md` — related: FK field constraints at DB layer
