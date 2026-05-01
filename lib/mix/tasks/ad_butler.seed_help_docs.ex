defmodule Mix.Tasks.AdButler.SeedHelpDocs do
  @shortdoc "Hashes, embeds, and upserts the help docs in priv/embeddings/help/"

  @moduledoc """
  One-shot mix task that walks `priv/embeddings/help/`, computes a SHA-256 of
  each `.md` file's contents, calls the configured embeddings service in a
  single batched request, and upserts each doc into the `embeddings` table
  under `kind = "doc_chunk"`.

  Re-running the task is safe — `Embeddings.upsert/1` skips re-embedding rows
  whose content_hash already matches via the `(kind, ref_id)` upsert path.

  `ref_id` is derived deterministically from the filename (SHA-256 → first 16
  bytes → UUID) so re-runs do not accumulate duplicate rows.

  ## Usage

      mix ad_butler.seed_help_docs

  Run after a code deploy that ships new help docs, or once locally to seed
  the dev embeddings table for chat smoke tests.
  """
  use Mix.Task

  alias AdButler.Embeddings

  @help_dir "priv/embeddings/help"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    docs = load_docs()
    Mix.shell().info("Seeding #{length(docs)} help doc embeddings…")

    case embed_all(docs) do
      {:ok, vectors} ->
        upsert_all(docs, vectors)
        Mix.shell().info("Seeded #{length(docs)} doc_chunk rows.")

      {:error, reason} ->
        Mix.shell().error("seed_help_docs failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp load_docs do
    base = Application.app_dir(:ad_butler, @help_dir)

    base
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      # Defends against future symlinks that escape the priv/embeddings/help
      # directory: Path.safe_relative/2 returns :error for paths that include
      # `..` segments or otherwise resolve outside `base`.
      relative = Path.relative_to(path, base)

      case Path.safe_relative(relative, base) do
        {:ok, _safe} ->
          filename = Path.basename(path)
          content = File.read!(path)

          [
            %{
              ref_id: doc_ref_id(filename),
              filename: filename,
              content: content,
              hash: Embeddings.hash_content(content)
            }
          ]

        :error ->
          Mix.shell().error("seed_help_docs: dropping unsafe path #{inspect(path)}")
          []
      end
    end)
  end

  defp embed_all([]), do: {:ok, []}

  defp embed_all(docs) do
    service = Application.get_env(:ad_butler, :embeddings_service, AdButler.Embeddings.Service)
    service.embed(Enum.map(docs, & &1.content))
  end

  defp upsert_all(docs, vectors) do
    rows =
      Enum.zip_with(docs, vectors, fn doc, vector ->
        %{
          kind: "doc_chunk",
          ref_id: doc.ref_id,
          embedding: vector,
          content_hash: doc.hash,
          content_excerpt: String.slice(doc.content, 0, 200),
          metadata: %{"filename" => doc.filename}
        }
      end)

    expected = length(docs)
    {:ok, count} = Embeddings.bulk_upsert(rows)

    if count == expected do
      Enum.each(docs, fn doc -> Mix.shell().info("  ✓ #{doc.filename}") end)
    else
      Mix.shell().error("seed_help_docs: bulk upsert wrote #{count}/#{expected} rows")
      exit({:shutdown, 1})
    end
  end

  # Deterministic UUID derived from the filename so reruns upsert the same row.
  # Derivation: SHA-256("doc_chunk:" <> filename) → first 16 bytes → UUID. The
  # "doc_chunk:" prefix namespaces these IDs so they cannot collide with future
  # ad_id / finding_id-derived UUIDs in the same `(kind, ref_id)` upsert space.
  # Stability matters: changing the derivation breaks the upsert invariant —
  # reruns would insert duplicate rows instead of replacing existing ones.
  defp doc_ref_id(filename) do
    <<bytes::binary-size(16), _::binary>> = :crypto.hash(:sha256, "doc_chunk:" <> filename)
    Ecto.UUID.cast!(bytes)
  end
end
