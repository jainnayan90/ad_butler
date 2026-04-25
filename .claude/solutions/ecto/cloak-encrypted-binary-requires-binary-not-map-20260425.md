---
module: "AdButler.LLM.Usage"
date: "2026-04-25"
problem_type: ecto_issue
component: ecto_schema
symptoms:
  - "Ecto changeset error: metadata is invalid [type: AdButler.Encrypted.Binary, validation: :cast]"
  - "Repo.insert returns {:error, changeset} with metadata cast failure when passing a plain map"
  - "Cloak.Ecto.Binary field silently rejects map values during cast"
root_cause: "Cloak.Ecto.Binary (and Cloak.Ecto.WrappedBinary) encrypt binary data. The Ecto type's cast/1 expects a binary string. A plain Elixir map is not a valid cast input — it must be JSON-encoded first."
severity: medium
tags: [cloak, encryption, ecto, schema, cast, binary, json, metadata]
---

# `Cloak.Ecto.Binary` Rejects Plain Maps — JSON-Encode Before Cast

## Symptoms

```elixir
# Changeset error:
[metadata: {"is invalid", [type: AdButler.Encrypted.Binary, validation: :cast]}]
```

Occurs when inserting a schema with a `Cloak.Ecto.Binary` field (or a module that `use`s it) and passing a map as the field value:

```elixir
%Usage{}
|> Usage.changeset(%{
  ...,
  metadata: %{"key" => "value"}  # map — INVALID
})
|> Repo.insert()
# => {:error, #Ecto.Changeset<errors: [metadata: {"is invalid", ...}]>}
```

## Investigation

1. **Read schema** — `field :metadata, AdButler.Encrypted.Binary` uses `Cloak.Ecto.Binary`.
2. **Read Cloak source** — `Cloak.Ecto.Binary.cast/1` calls `Ecto.Type.cast(:string, value)` — it only accepts binary strings.
3. **Root cause**: `Cloak.Ecto.Binary` is a binary type. Maps are not binaries. Ecto's cast pipeline rejects the map before encryption even runs.

## Root Cause

`Cloak.Ecto.Binary` (via `use Cloak.Ecto.Binary`) wraps `Ecto.Type` with `:binary` as the underlying type. The `cast/1` callback only accepts binary values. A plain Elixir map must be serialised to a binary string (e.g. JSON) before being cast.

```elixir
# BROKEN — map passed directly to a Binary field
attrs = %{metadata: %{"key" => "secret"}}
Usage.changeset(%Usage{}, attrs)
# => cast error

# FIXED — JSON-encode the map first
attrs = %{metadata: Jason.encode!(%{"key" => "secret"})}
Usage.changeset(%Usage{}, attrs)
# => valid changeset; Cloak encrypts the JSON string
```

When reading back, `Cloak.Ecto.Binary` decrypts and returns the raw binary (JSON string). You must `Jason.decode!/1` to get the map back.

## Solution

JSON-encode maps before passing to a `Cloak.Ecto.Binary` field. Do this in the layer that builds the attrs (e.g. a telemetry handler or context function), not in the changeset:

```elixir
# In the caller (e.g. UsageHandler.build_attrs/3):
defp encode_metadata(nil), do: nil
defp encode_metadata(map) when is_map(map) do
  case Jason.encode(map) do
    {:ok, json} -> json
    {:error, _} -> nil  # never raise from a telemetry handler
  end
end
```

When reading back the decrypted value:

```elixir
row = Repo.get!(Usage, id)
map = Jason.decode!(row.metadata)  # decrypted JSON string → map
```

### Files Changed

- `lib/ad_butler/llm/usage_handler.ex` — `encode_metadata/1` helper
- `test/ad_butler/llm/usage_handler_test.exs` — assert on `Jason.decode!(row.metadata)` not `row.metadata`

## Prevention

- [ ] `Cloak.Ecto.Binary` stores **binary strings**, not Elixir terms. Always JSON-encode maps before passing to these fields.
- [ ] When reading an encrypted field back from the DB, the decrypted value is the same type that was inserted — if you inserted a JSON string, you get a JSON string back (not a map).
- [ ] Do NOT use `Jason.encode!/1` inside a telemetry handler — use `Jason.encode/1` and handle `{:error, _}`. A raise inside a telemetry handler propagates to the process that called `:telemetry.execute/3`.
- [ ] Test encryption by reading the raw column with `Repo.query!("SELECT col FROM table WHERE ...")` and asserting the raw value is **not** equal to the plaintext JSON string.

## Related

- `solutions/config/cloak-key-must-be-32-bytes-aes-256-gcm-20260421.md`
- `lib/ad_butler/encrypted/binary.ex` — uses `Cloak.Ecto.Binary, vault: AdButler.Vault`
