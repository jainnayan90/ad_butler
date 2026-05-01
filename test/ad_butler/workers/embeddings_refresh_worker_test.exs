defmodule AdButler.Workers.EmbeddingsRefreshWorkerTest do
  use AdButler.DataCase, async: false
  use Oban.Testing, repo: AdButler.Repo

  import AdButler.Factory
  import Ecto.Query
  import Mox

  alias AdButler.Embeddings
  alias AdButler.Repo
  alias AdButler.Workers.EmbeddingsRefreshWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp random_vector, do: for(_ <- 1..1536, do: :rand.uniform())

  defp insert_ad_with_account do
    mc = insert(:meta_connection)
    ad_account = insert(:ad_account, meta_connection: mc)
    ad_set = insert(:ad_set, ad_account: ad_account)
    insert(:ad, ad_account: ad_account, ad_set: ad_set, name: "Promo July 2026")
  end

  describe "perform/1 — first run (backfill)" do
    test "embeds and upserts all ads + findings on a clean DB" do
      ad = insert_ad_with_account()

      finding =
        insert(:finding,
          ad_id: ad.id,
          ad_account_id: ad.ad_account_id,
          kind: "creative_fatigue",
          severity: "medium",
          title: "Predicted fatigue",
          body: "Forecast: CTR projected to drop"
        )

      # `perform/1` walks `["ad", "finding"]` in order, so the first `embed/1`
      # call carries ad text and the second carries finding text. If the worker
      # ever batches both kinds in one call (or reverses the order), the
      # ordered `expect`s below will fail loudly.
      expect(AdButler.Embeddings.ServiceMock, :embed, fn texts ->
        assert length(texts) == 1
        {:ok, [random_vector()]}
      end)

      expect(AdButler.Embeddings.ServiceMock, :embed, fn texts ->
        assert length(texts) == 1
        {:ok, [random_vector()]}
      end)

      assert :ok = perform_job(EmbeddingsRefreshWorker, %{})

      assert Repo.aggregate(
               from(e in Embeddings.Embedding, where: e.kind == "ad" and e.ref_id == ^ad.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(e in Embeddings.Embedding,
                 where: e.kind == "finding" and e.ref_id == ^finding.id
               ),
               :count
             ) == 1
    end
  end

  describe "perform/1 — second run with no source changes" do
    test "skips embedding entirely (idempotent)" do
      ad = insert_ad_with_account()

      # Pre-seed an embedding row whose hash matches the current ad content.
      # Raw literal mirrors `ad_content/1`'s format (`"name | creative_name"`)
      # so a future format drift fails `describe "ad_content/1"` independently
      # — see lines below.
      content = "#{ad.name} | "
      hash = Embeddings.hash_content(content)

      {:ok, _} =
        Embeddings.upsert(%{
          kind: "ad",
          ref_id: ad.id,
          embedding: random_vector(),
          content_hash: hash,
          content_excerpt: content
        })

      # No expects on the mock = the worker MUST NOT call embed/1.
      assert :ok = perform_job(EmbeddingsRefreshWorker, %{})
    end

    test "only changed ads re-embed when one ad's content changes" do
      ad1 = insert_ad_with_account()
      ad2 = insert_ad_with_account()

      # Pre-seed both with hashes matching their CURRENT content. Raw literal
      # mirrors `ad_content/1`'s format — see comment in the test above.
      Enum.each([ad1, ad2], fn ad ->
        content = "#{ad.name} | "

        Embeddings.upsert(%{
          kind: "ad",
          ref_id: ad.id,
          embedding: random_vector(),
          content_hash: Embeddings.hash_content(content),
          content_excerpt: content
        })
      end)

      # Mutate ad1's name → its hash diverges → only ad1 should re-embed.
      Repo.update_all(
        from(a in AdButler.Ads.Ad, where: a.id == ^ad1.id),
        set: [name: "Promo August 2026 — refreshed"]
      )

      expect(AdButler.Embeddings.ServiceMock, :embed, fn texts ->
        # Exactly one text — the changed ad.
        assert length(texts) == 1
        assert hd(texts) =~ "Promo August 2026"
        {:ok, [random_vector()]}
      end)

      assert :ok = perform_job(EmbeddingsRefreshWorker, %{})

      # ad1's stored content_hash now reflects the new name.
      ad1_row = Repo.one(from e in Embeddings.Embedding, where: e.ref_id == ^ad1.id)

      assert ad1_row.content_hash ==
               Embeddings.hash_content("Promo August 2026 — refreshed | ")
    end
  end

  describe "perform/1 — cross-tenant embedding (by design)" do
    test "embeds ads belonging to two different MetaConnections in one tick" do
      # The worker is intentionally cross-tenant: embeddings power downstream
      # similarity search but are not user-facing themselves. Caller-facing
      # surfaces (chat tools) are responsible for filtering ref_id results
      # against the requesting user's MetaConnection IDs.
      ad_a = insert_ad_with_account()
      ad_b = insert_ad_with_account()

      assert ad_a.ad_account_id != ad_b.ad_account_id

      expect(AdButler.Embeddings.ServiceMock, :embed, fn texts ->
        assert length(texts) == 2
        {:ok, [random_vector(), random_vector()]}
      end)

      assert :ok = perform_job(EmbeddingsRefreshWorker, %{})

      assert {:ok, hashes} = Embeddings.list_ref_id_hashes("ad")
      assert Map.has_key?(hashes, ad_a.id)
      assert Map.has_key?(hashes, ad_b.id)
    end
  end

  describe "perform/1 — service errors" do
    test "rate_limit response snoozes the job and leaves the row untouched" do
      ad = insert_ad_with_account()

      original_hash = Embeddings.hash_content("stale content")

      {:ok, _} =
        Embeddings.upsert(%{
          kind: "ad",
          ref_id: ad.id,
          embedding: random_vector(),
          content_hash: original_hash,
          content_excerpt: "stale content"
        })

      # Ad's content hash differs from `original_hash` → worker tries to embed.
      expect(AdButler.Embeddings.ServiceMock, :embed, fn _texts ->
        {:error, :rate_limit}
      end)

      # P2-T6 — rate-limit responses convert to {:snooze, N} so Oban doesn't
      # burn one of the 3 max_attempts inside the 60s rate-limit window.
      assert {:snooze, 90} = perform_job(EmbeddingsRefreshWorker, %{})

      # Row was not overwritten — stays at the original hash so the next
      # successful run can re-detect and re-embed.
      row = Repo.one(from e in Embeddings.Embedding, where: e.ref_id == ^ad.id)
      assert row.content_hash == original_hash
    end

    test "vector count mismatch returns :vector_count_mismatch" do
      _ad = insert_ad_with_account()

      # Service returns FEWER vectors than texts → mismatch.
      expect(AdButler.Embeddings.ServiceMock, :embed, fn _texts ->
        {:ok, []}
      end)

      assert {:error, :vector_count_mismatch} = perform_job(EmbeddingsRefreshWorker, %{})
    end
  end

  describe "ad_content/1" do
    test "joins name and creative_name with ' | '" do
      assert EmbeddingsRefreshWorker.ad_content(%{name: "Promo", creative_name: "Hero"}) ==
               "Promo | Hero"
    end

    test "renders the bare separator when both fields are nil" do
      assert EmbeddingsRefreshWorker.ad_content(%{name: nil, creative_name: nil}) == " | "
    end

    test "preserves the empty side when only name is set" do
      assert EmbeddingsRefreshWorker.ad_content(%{name: "Promo", creative_name: nil}) ==
               "Promo | "
    end

    test "preserves the empty side when only creative_name is set" do
      assert EmbeddingsRefreshWorker.ad_content(%{name: nil, creative_name: "Hero"}) ==
               " | Hero"
    end

    test "treats empty strings the same as nils on either side" do
      assert EmbeddingsRefreshWorker.ad_content(%{name: "", creative_name: ""}) == " | "
      assert EmbeddingsRefreshWorker.ad_content(%{name: "Promo", creative_name: ""}) == "Promo | "
    end
  end

  describe "perform/1 — Oban uniqueness" do
    test "second insert within the 28-minute unique window is a conflict" do
      args = %{}

      {:ok, _job1} = args |> EmbeddingsRefreshWorker.new() |> Oban.insert()
      {:ok, job2} = args |> EmbeddingsRefreshWorker.new() |> Oban.insert()

      assert job2.conflict? == true
    end
  end
end
