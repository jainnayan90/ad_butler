# Test Review: week-2-review-fixes-2

⚠️ EXTRACTED FROM AGENT MESSAGE (agent Write access denied)

**Status**: PASS WITH WARNINGS
**Issues**: 3 warnings · 1 suggestion

---

## Warnings

### W1 — `get_finding/2` missing malformed UUID test

Three cases cover happy path, cross-tenant, and well-formed-but-nonexistent UUID. No test for a malformed UUID string (e.g. `"not-a-uuid"`). `Repo.get/2` with `:binary_id` raises `Ecto.Query.CastError` for invalid UUIDs unless rescued. A caller passing a raw URL segment gets an unexpected raise instead of `{:error, :not_found}`.

```elixir
test "returns {:error, :not_found} for malformed UUID" do
  user = insert(:user)
  _aa = insert_ad_account_for_user(user)
  assert {:error, :not_found} = Analytics.get_finding(user, "not-a-uuid")
end
```

### W2 — Health score idempotency test: wall-clock boundary risk

Both `perform_job` calls resolve `six_hour_bucket/0` milliseconds apart in practice. But if the test runs at a 6-hour UTC boundary (00:00, 06:00, 12:00, 18:00) and the two calls straddle it, they produce different `computed_at` buckets — count becomes 2 and assertion fails. Low-probability flake.

### W3 — `acknowledge_finding/2` missing nonexistent-ID test

No test for `acknowledge_finding(user, Ecto.UUID.generate())` on a completely nonexistent ID. Covered transitively through `get_finding/2` tests but not explicit.

---

## Suggestions

- `get_unresolved_finding/2` test calls `Repo.update_all` directly for setup — acceptable, but if `resolve_finding/2` is added to the context later, prefer it here for consistency.
