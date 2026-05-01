---
title: "Path.safe_relative/2 defends an admin file walker against future symlinks"
module: "Mix.Tasks.AdButler.SeedHelpDocs"
date: "2026-05-01"
problem_type: hardening
component: file_system
symptoms:
  - "Mix task walks priv/embeddings/help/ via Path.wildcard/1 and File.read!/1 each match"
  - "Future symlink dropped into the priv directory could escape the intended root"
  - "Defense in depth — admin context limits real attack surface today"
---

## Root cause

`Path.wildcard/1` resolves matches relative to the working directory. If a
symlink in the walked tree points outside the intended root (e.g. `../etc/passwd`),
`File.read!/1` happily follows it. Mix tasks run with full file-system permissions
of the operator, so the failure mode is silent privilege escalation if an attacker
can drop a file into `priv/embeddings/help/`.

## Fix

Wrap each path with `Path.safe_relative/2` against the intended base directory.
Calls returning `:error` are dropped with a warning; callers see the count
mismatch downstream.

```elixir
defp load_docs do
  base = Application.app_dir(:ad_butler, @help_dir)

  base
  |> Path.join("*.md")
  |> Path.wildcard()
  |> Enum.flat_map(fn path ->
    relative = Path.relative_to(path, base)

    case Path.safe_relative(relative, base) do
      {:ok, _safe} ->
        # ... real work
        [%{...}]

      :error ->
        Mix.shell().error("seed_help_docs: dropping unsafe path #{inspect(path)}")
        []
    end
  end)
end
```

## Verification — Path.safe_relative/2 contract (Elixir 1.14+)

```elixir
Path.safe_relative("billing.md", "/tmp/help")        #=> {:ok, "billing.md"}
Path.safe_relative("../../etc/passwd", "/tmp/help")  #=> :error
```

The first arg must be RELATIVE (use `Path.relative_to/2` first). The second arg
is the allowed root — any `..` segment that would resolve outside it returns
`:error`. Pure-Elixir delegation to `:filelib.safe_relative_path/2`.

## Companion: Application.app_dir over Path.expand

`Application.app_dir(:ad_butler, "priv/embeddings/help")` is the release-correct
way to resolve `priv/`. `Path.expand("priv/...")` works in dev but breaks under
mix releases (where `priv/` is at `_build/.../<app>/priv/...`).

## Why "future-symlink" is not paranoia

The seed task is admin-curated TODAY (only operators run it), but help docs are
the kind of asset frequently moved into shared CMS/git submodules where contributor
trust changes. Adding the defense at low cost (~10 LOC) prevents a future
contributor from introducing the symlink risk silently.
