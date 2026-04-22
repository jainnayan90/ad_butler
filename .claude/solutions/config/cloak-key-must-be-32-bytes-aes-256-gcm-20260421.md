---
module: "AdButler.Vault"
date: "2026-04-21"
problem_type: configuration_error
component: cloak_encryption
symptoms:
  - "Cloak vault fails to initialize or silently pads key in dev environment"
  - "Dev key decodes to 27 bytes instead of required 32 bytes for AES-256-GCM"
  - "Mismatch between dev and test key lengths causes inconsistent behavior"
root_cause: "Human-readable string used as Cloak key decodes to fewer than 32 bytes; AES-256-GCM requires exactly 32 bytes"
severity: high
tags: [cloak, encryption, aes-gcm, configuration, vault, key-length]
---

# Cloak AES-256-GCM Key Must Decode to Exactly 32 Bytes

## Symptoms

Dev server crashes at vault initialization, or Cloak silently fails/pads the key,
causing encrypt/decrypt errors at runtime. The symptom may not appear until encrypted
fields are first accessed.

In this codebase, the dev key `"YWRfYnV0bGVyX2Rldl9rZXlfZm9yX2xvY2Fs"` (Base64 of
`"ad_butler_dev_key_for_local"`) decodes to **27 bytes** — 5 bytes short of the 32
required by AES-256-GCM.

## Investigation

```bash
# Quick check: decode the current key and count bytes
elixir -e 'IO.puts byte_size(Base.decode64!("YWRfYnV0bGVyX2Rldl9rZXlfZm9yX2xvY2Fs"))'
# → 27  (WRONG — must be 32)

elixir -e 'IO.puts byte_size(Base.decode64!("YWRfYnV0bGVyX3Rlc3Rfa2V5X2Zvcl90ZXN0aW5nISE="))'
# → 32  (OK)
```

The test key was correct (32 bytes); the dev key was not.

## Root Cause

A human-readable string was Base64-encoded and used as the Cloak key. The string length
determines the byte count, and arbitrary strings rarely land on 32 bytes. AES-256-GCM
requires **exactly 256 bits = 32 bytes** — no more, no less.

```elixir
# Broken — human-readable string, wrong byte length
key: Base.decode64!("YWRfYnV0bGVyX2Rldl9rZXlfZm9yX2xvY2Fs")  # 27 bytes
```

## Solution

Generate a cryptographically random 32-byte key:

```bash
elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'
# → e.g. "DWd3enw3lCLQQhOo7zcLHBUds5byv33NIJuHMvqG114="
```

```elixir
# Fixed — CSPRNG key, guaranteed 32 bytes
config :ad_butler, AdButler.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("DWd3enw3lCLQQhOo7zcLHBUds5byv33NIJuHMvqG114=")}
  ]
```

### Files Changed

- `config/dev.exs:98` — Replaced 27-byte human-readable key with 32-byte CSPRNG key

## Prevention

- [ ] Never use human-readable strings as Cloak keys — always use `:crypto.strong_rand_bytes(32)`
- [ ] Verify key byte length at setup: `byte_size(Base.decode64!(key)) == 32`
- [ ] In CI, add a startup assertion or use `mix cloak.generate_key` if available
- [ ] Test key and dev key should both be generated the same way — if test passes and dev crashes, check key lengths first
