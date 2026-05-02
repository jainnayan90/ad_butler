---
title: "Per-key rescue when normalizing LLM/external map keys to existing atoms (don't drop valid keys)"
module: "Map / String.to_existing_atom"
date: "2026-05-02"
problem_type: logic_error
component: elixir_idiom
symptoms:
  - "External-input map gets normalised to atom keys via Map.new/2 with a rescue around the whole call"
  - "One unknown string key triggers ArgumentError; the entire Map.new rescues, dropping ALL keys including valid ones"
  - "Fallback path returns only pre-existing atom keys (often an empty map) — schema validator downstream produces a misleading 'missing required field' error"
  - "User reports 'tool params disappeared' or 'schema rejected my input' when only one extra key was bad"
root_cause: "`Map.new/2` over an enumerable that raises mid-iteration discards all accumulated work — there is no partial result on rescue. Wrapping the WHOLE call in a single rescue means any one bad key drops every other valid key. The intent is 'drop the unknown key, keep the rest', but `Map.new` plus a single `rescue ArgumentError` does the opposite."
severity: medium
tags: [elixir, idiom, atom, string-to-existing-atom, llm, jido, error-handling, map]
related_solutions: []
---

## Problem

Tool calls from an LLM arrive as `%{"ad_ids" => [...], "limit" => 5, "spurious_extra" => "x"}`. The agent loop wants to convert to atom keys for `Jido.Action`'s schema. The naive approach:

```elixir
defp normalise_params(args) when is_map(args) do
  Map.new(args, fn
    {k, v} when is_atom(k) -> {k, v}
    {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
  end)
rescue
  ArgumentError ->
    # drop unknown atom keys, keep the valid ones
    Map.new(Enum.filter(args, fn {k, _} -> is_atom(k) end))
end
```

When the LLM emits a key the schema doesn't recognise, `String.to_existing_atom/1` raises `ArgumentError`. The whole `Map.new/2` unwinds — every accumulated `{key, value}` discarded. The rescue branch only keeps PRE-EXISTING atom keys (which is usually none of them, since LLM-emitted maps are all binary-keyed).

Net effect: one bad key drops everything. Jido sees `%{}` and returns a confusing schema-validation error like `:missing_required_field, :ad_ids` — when the LLM actually sent `ad_ids` correctly.

## Solution

Iterate per-key with `Enum.reduce/3`, `try`/`rescue` per-key. Accumulate `{kept, unknown}`. Only the offending key is dropped; everything else survives. Log unknown keys ONCE at the end, never per-key.

```elixir
defp normalise_params(args) when is_map(args) do
  {kept, unknown} =
    Enum.reduce(args, {%{}, []}, fn
      {k, v}, {acc, unknown} when is_atom(k) ->
        {Map.put(acc, k, v), unknown}

      {k, v}, {acc, unknown} when is_binary(k) ->
        try do
          {Map.put(acc, String.to_existing_atom(k), v), unknown}
        rescue
          ArgumentError -> {acc, [k | unknown]}
        end
    end)

  if unknown != [] do
    Logger.warning("chat: LLM emitted unknown tool param key", unknown_keys: unknown)
  end

  kept
end
```

## Why each piece matters

- **`Enum.reduce/3` over `Map.new/2`** — `reduce` gives you a running accumulator that survives a per-key rescue; `Map.new` does not.
- **Per-key `try/rescue`** — only the offending key is caught. Valid binary keys mapping to existing atoms still convert successfully.
- **`String.to_existing_atom/1`, never `String.to_atom/1`** — Iron Law: never let user/external input create atoms (atom table exhaustion DoS). The rescue branch handles the "atom doesn't exist" case explicitly.
- **Log keys, never values** — `unknown_keys: [...]` in metadata. Values may carry secrets / PII. The keys are the LLM's own field names, safe to log. Add the metadata key to the Logger allowlist.
- **Single `Logger.warning` at the end** — not per-key. Keeps the log surface bounded even if the LLM emits 50 unknown keys.

## When to use

- Any time you normalize an external-input map to atom keys and the schema permits dropping unknowns.
- LLM tool params, JSON API request bodies with optional unknown fields, deserialised state from external systems.

## When NOT to use

- When the schema requires "reject the WHOLE input on any unknown key." For that, return `{:error, :unknown_keys, [...]}` from `normalise_params/1` and let the caller surface a 400 / schema error to the user.
- When key conversion is happening inside `Ecto.Changeset.cast/3` — the changeset already handles unknown keys correctly via its allowlist; a custom normalize step there is redundant.

## Detection

`grep` for `Map.new` followed by a single rescue clause around the whole call:

```bash
rg -A3 "Map\.new\(.*?String\.to_existing_atom" -- '*.ex'
```

Any match with a `rescue ArgumentError -> ` outside the inner conversion is a candidate for refactoring to per-key reduce.
