defmodule AdButler.Workers.EmbeddingsRefreshWorker do
  @moduledoc """
  Oban cron worker (every 30 minutes) that refreshes embeddings for ads and
  findings whose source content has changed.

  Per kind, the worker computes a SHA-256 of the current source text, compares
  to the stored `content_hash` on the existing embedding row, and re-embeds
  only the rows that differ (or have no row yet). Up to `@batch_size` rows per
  kind per run — the cron's 30-minute cadence catches up large backfills over
  multiple ticks rather than starving the embeddings provider in one shot.

  Source text shape:
    * ads: `"<ad.name> | <creative.name>"` (creative is `nil` if Meta deleted it)
    * findings: `"<finding.title>\\n\\n<finding.body>"`

  On a `Embeddings.Service.embed/1` failure (rate limit, transient API error),
  the worker logs and returns `{:error, reason}` — Oban retries via the
  worker's `max_attempts: 3`. The unembedded rows stay at their stale hash, so
  a successful retry picks them up on the next call.
  """
  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 3,
    unique: [period: 1_680, fields: [:queue, :worker]]

  require Logger

  alias AdButler.Ads
  alias AdButler.Analytics
  alias AdButler.Embeddings

  @batch_size 100
  @excerpt_length 200

  @doc """
  5 min cap on a worker that does sequential Repo + HTTP work; lifeline rescue
  still catches at 30 min as a backstop.
  """
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc "Refreshes a batch of changed/new ad and finding embeddings."
  @impl Oban.Worker
  def perform(_job) do
    ad_result = refresh_kind("ad")
    finding_result = refresh_kind("finding")

    # Errors take precedence over snoozes — snoozing on a rate limit must not
    # mask a hard failure on the other kind. Oban will retry on error and
    # re-attempt both kinds; the next retry's snooze (if still rate-limited)
    # will re-surface only after the error is resolved.
    case {ad_result, finding_result} do
      {:ok, :ok} -> :ok
      {{:error, r}, _} -> {:error, r}
      {_, {:error, r}} -> {:error, r}
      {{:snooze, s}, _} -> {:snooze, s}
      {_, {:snooze, s}} -> {:snooze, s}
    end
  end

  defp refresh_kind(kind) do
    case Embeddings.list_ref_id_hashes(kind) do
      {:ok, existing_hashes} ->
        candidates = build_candidates(kind, existing_hashes)
        embed_and_upsert(kind, candidates)

      {:error, {:invalid_kind, _}} ->
        raise "BUG: EmbeddingsRefreshWorker called with invalid kind #{inspect(kind)}"
    end
  end

  defp build_candidates("ad", existing_hashes) do
    Ads.unsafe_list_ads_with_creative_names()
    |> filter_to_changed(existing_hashes, &ad_content/1)
  end

  defp build_candidates("finding", existing_hashes) do
    Analytics.unsafe_list_all_findings_for_embedding()
    |> filter_to_changed(existing_hashes, &finding_content/1)
  end

  defp filter_to_changed(rows, existing_hashes, content_fn) do
    rows
    |> Enum.flat_map(fn row ->
      content = content_fn.(row)
      hash = Embeddings.hash_content(content)

      if Map.get(existing_hashes, row.id) != hash do
        [%{ref_id: row.id, content: content, hash: hash}]
      else
        []
      end
    end)
    |> Enum.take(@batch_size)
  end

  @doc """
  Renders the source-text representation embedded for an ad row. Public so
  tests can assert against the format without re-implementing the format
  string (which would silently drift when `build_candidates/2` changes).
  """
  @spec ad_content(%{
          optional(:name) => String.t() | nil,
          optional(:creative_name) => String.t() | nil
        }) :: String.t()
  def ad_content(%{name: name, creative_name: creative_name}) do
    "#{name || ""} | #{creative_name || ""}"
  end

  @doc """
  Renders the source-text representation embedded for a finding row. Public
  for the same reason as `ad_content/1` — keeps tests aligned with worker
  output.
  """
  @spec finding_content(%{
          optional(:title) => String.t() | nil,
          optional(:body) => String.t() | nil
        }) :: String.t()
  def finding_content(%{title: title, body: body}) do
    "#{title || ""}\n\n#{body || ""}"
  end

  defp embed_and_upsert(_kind, []), do: :ok

  defp embed_and_upsert(kind, candidates) do
    service = embeddings_service()
    texts = Enum.map(candidates, & &1.content)

    case service.embed(texts) do
      {:ok, vectors} when length(vectors) == length(candidates) ->
        case upsert_batch(kind, candidates, vectors) do
          :ok ->
            Logger.info("embeddings_refresh: upserted batch",
              kind: kind,
              count: length(candidates)
            )

            :ok

          {:error, _} = error ->
            error
        end

      {:ok, vectors} ->
        Logger.error("embeddings_refresh: vector count mismatch",
          kind: kind,
          count: length(candidates),
          vectors_received: length(vectors)
        )

        {:error, :vector_count_mismatch}

      {:error, reason} ->
        if rate_limit_error?(reason) do
          Logger.warning("embeddings_refresh: rate limited, snoozing",
            kind: kind,
            count: length(candidates)
          )

          {:snooze, 90}
        else
          Logger.error("embeddings_refresh: embed failed", kind: kind, reason: reason)
          {:error, reason}
        end
    end
  end

  # Match ReqLLM's rate-limit shape (HTTP 429) and the simpler atom returned by
  # tests/mocks. Snoozing for 90s keeps the next attempt outside the typical
  # 60s rate-limit window so a single retry usually clears.
  #
  # Under Oban OSS basic engine, `snooze_job/3` does `inc: [max_attempts: 1]`
  # (deps/oban/lib/oban/engines/basic.ex:263-272), compensating for the
  # attempt counter incremented at job start — snoozes therefore do NOT
  # consume retry budget. `max_attempts: 3` covers three genuine error
  # retries independent of how many times the job is snoozed for rate limits.
  #
  # The struct is matched structurally rather than via `alias` so a ReqLLM
  # version bump that renames the module (e.g. `ReqLLM.Error.API.Request` →
  # `ReqLLM.Errors.RateLimited`) falls through to the generic `{:error, _}`
  # path with a logged reason rather than a compile error elsewhere — the
  # source of truth is `deps/req_llm/lib/req_llm/error.ex`.
  defp rate_limit_error?(:rate_limit), do: true
  defp rate_limit_error?(%{__struct__: ReqLLM.Error.API.Request, status: 429}), do: true
  defp rate_limit_error?(_), do: false

  defp upsert_batch(kind, candidates, vectors) do
    rows =
      Enum.zip_with(candidates, vectors, fn c, vector ->
        %{
          kind: kind,
          ref_id: c.ref_id,
          embedding: vector,
          content_hash: c.hash,
          content_excerpt: String.slice(c.content, 0, @excerpt_length)
        }
      end)

    expected = length(rows)

    case Embeddings.bulk_upsert(rows) do
      {:ok, ^expected} ->
        :ok

      {:ok, count} ->
        Logger.error("embeddings_refresh: partial upsert",
          kind: kind,
          count: expected,
          failure_count: expected - count
        )

        {:error, :partial_upsert_failure}
    end
  end

  defp embeddings_service do
    Application.get_env(:ad_butler, :embeddings_service, AdButler.Embeddings.Service)
  end
end
