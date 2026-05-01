defmodule AdButler.EmbeddingsTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Embeddings
  alias AdButler.Embeddings.Embedding

  defp random_vector(dim \\ 1536) do
    for _ <- 1..dim, do: :rand.uniform()
  end

  defp ones_vector(dim \\ 1536) do
    for _ <- 1..dim, do: 1.0
  end

  defp shifted_vector(dim, offset) do
    for i <- 1..dim, do: 1.0 - (rem(i, 7) + offset) * 0.0001
  end

  describe "hash_content/1" do
    test "returns 64-char lowercase hex digest" do
      hash = Embeddings.hash_content("hello world")
      assert byte_size(hash) == 64
      assert hash == String.downcase(hash)
      assert hash =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "is deterministic" do
      assert Embeddings.hash_content("a | b") == Embeddings.hash_content("a | b")
    end

    test "differs on differing input" do
      refute Embeddings.hash_content("a") == Embeddings.hash_content("b")
    end
  end

  describe "upsert/1" do
    test "inserts a new embedding row" do
      ref_id = Ecto.UUID.generate()

      assert {:ok, %Embedding{} = e} =
               Embeddings.upsert(%{
                 kind: "doc_chunk",
                 ref_id: ref_id,
                 embedding: random_vector(),
                 content_hash: Embeddings.hash_content("hello"),
                 content_excerpt: "hello"
               })

      assert e.kind == "doc_chunk"
      assert e.ref_id == ref_id
    end

    test "updates on (kind, ref_id) conflict" do
      ref_id = Ecto.UUID.generate()
      v1 = random_vector()
      v2 = random_vector()

      {:ok, e1} =
        Embeddings.upsert(%{
          kind: "doc_chunk",
          ref_id: ref_id,
          embedding: v1,
          content_hash: Embeddings.hash_content("v1"),
          content_excerpt: "v1"
        })

      {:ok, e2} =
        Embeddings.upsert(%{
          kind: "doc_chunk",
          ref_id: ref_id,
          embedding: v2,
          content_hash: Embeddings.hash_content("v2"),
          content_excerpt: "v2"
        })

      # Same row id (UPDATE, not INSERT).
      assert e1.id == e2.id
      assert e2.content_excerpt == "v2"
    end

    test "rejects unknown kind" do
      assert {:error, %Ecto.Changeset{}} =
               Embeddings.upsert(%{
                 kind: "campaign",
                 ref_id: Ecto.UUID.generate(),
                 embedding: random_vector(),
                 content_hash: Embeddings.hash_content("x")
               })
    end

    test "rejects malformed content_hash" do
      assert {:error, %Ecto.Changeset{}} =
               Embeddings.upsert(%{
                 kind: "ad",
                 ref_id: Ecto.UUID.generate(),
                 embedding: random_vector(),
                 content_hash: "not-a-sha256"
               })
    end
  end

  describe "nearest/3" do
    test "returns rows ordered by ascending cosine distance" do
      # Anchor: all-ones vector. Insert one near (small offset), one far (large offset).
      # NOTE: HNSW is approximate — the wider-gap `partial_ones` strategy in
      # the limit test below is the more robust pattern. This test relies on
      # the offset-1 vs offset-50 gap being preserved by HNSW under load; if
      # this flakes in CI, switch to `partial_ones(1536, k)` per the third
      # test in this describe block.
      anchor = ones_vector()
      near = shifted_vector(1536, 1)
      far = shifted_vector(1536, 50)

      {:ok, near_row} =
        Embeddings.upsert(%{
          kind: "doc_chunk",
          ref_id: Ecto.UUID.generate(),
          embedding: near,
          content_hash: Embeddings.hash_content("near"),
          content_excerpt: "near"
        })

      {:ok, far_row} =
        Embeddings.upsert(%{
          kind: "doc_chunk",
          ref_id: Ecto.UUID.generate(),
          embedding: far,
          content_hash: Embeddings.hash_content("far"),
          content_excerpt: "far"
        })

      assert {:ok, results} = Embeddings.nearest("doc_chunk", anchor, 2)
      assert length(results) == 2
      assert Enum.at(results, 0).id == near_row.id
      assert Enum.at(results, 1).id == far_row.id
    end

    test "filters by kind" do
      # Insert two embeddings under different kinds with similar vectors.
      v = ones_vector()

      {:ok, _ad_row} =
        Embeddings.upsert(%{
          kind: "ad",
          ref_id: Ecto.UUID.generate(),
          embedding: v,
          content_hash: Embeddings.hash_content("ad")
        })

      {:ok, doc_row} =
        Embeddings.upsert(%{
          kind: "doc_chunk",
          ref_id: Ecto.UUID.generate(),
          embedding: v,
          content_hash: Embeddings.hash_content("doc")
        })

      assert {:ok, [%Embedding{} = result]} = Embeddings.nearest("doc_chunk", v, 5)
      assert result.id == doc_row.id
    end

    test "returns {:error, {:invalid_kind, kind}} for unknown kinds" do
      assert {:error, {:invalid_kind, "campaign"}} =
               Embeddings.nearest("campaign", ones_vector(), 5)
    end

    test "respects the limit and returns the closest+second-closest rows" do
      anchor = ones_vector()

      # Three rows with strictly distinguishable cosine distances to `anchor`.
      # `partial_ones(1536, k)` matches the first `k` components of `anchor` and
      # zeroes the rest — the more components match, the smaller the cosine
      # distance. Wide gaps (1535/1336/1036 ones) so HNSW's approximate search
      # reliably orders them under concurrent test load.
      {:ok, closest_row} = upsert_doc(partial_ones(1536, 1535), "ones_1535")
      {:ok, second_row} = upsert_doc(partial_ones(1536, 1336), "ones_1336")
      {:ok, _far_row} = upsert_doc(partial_ones(1536, 1036), "ones_1036")

      assert {:ok, results} = Embeddings.nearest("doc_chunk", anchor, 2)
      assert length(results) == 2
      assert Enum.at(results, 0).id == closest_row.id
      assert Enum.at(results, 1).id == second_row.id
    end
  end

  defp upsert_doc(vector, hash_seed) do
    Embeddings.upsert(%{
      kind: "doc_chunk",
      ref_id: Ecto.UUID.generate(),
      embedding: vector,
      content_hash: Embeddings.hash_content(hash_seed)
    })
  end

  defp partial_ones(dim, ones_count) do
    for i <- 1..dim, do: if(i <= ones_count, do: 1.0, else: 0.0)
  end

  describe "list_ref_id_hashes/1" do
    test "returns map of ref_id => content_hash for the given kind" do
      ref_id = Ecto.UUID.generate()
      hash = Embeddings.hash_content("source content")

      {:ok, _} =
        Embeddings.upsert(%{
          kind: "ad",
          ref_id: ref_id,
          embedding: random_vector(),
          content_hash: hash
        })

      assert {:ok, result} = Embeddings.list_ref_id_hashes("ad")
      assert Map.get(result, ref_id) == hash
    end

    test "returns {:error, {:invalid_kind, kind}} for unknown kinds" do
      assert {:error, {:invalid_kind, "campaign"}} =
               Embeddings.list_ref_id_hashes("campaign")
    end

    test "ignores other kinds" do
      ad_id = Ecto.UUID.generate()
      finding_id = Ecto.UUID.generate()

      Embeddings.upsert(%{
        kind: "ad",
        ref_id: ad_id,
        embedding: random_vector(),
        content_hash: Embeddings.hash_content("ad source")
      })

      Embeddings.upsert(%{
        kind: "finding",
        ref_id: finding_id,
        embedding: random_vector(),
        content_hash: Embeddings.hash_content("finding source")
      })

      assert {:ok, ad_hashes} = Embeddings.list_ref_id_hashes("ad")
      assert Map.has_key?(ad_hashes, ad_id)
      refute Map.has_key?(ad_hashes, finding_id)
    end
  end

  describe "tenant_filter_results/2" do
    test "drops ad rows whose ref_id belongs to another tenant" do
      mc_a = insert(:meta_connection)
      mc_b = insert(:meta_connection)

      aa_a = insert(:ad_account, meta_connection: mc_a)
      aa_b = insert(:ad_account, meta_connection: mc_b)

      ad_a = insert(:ad, ad_account: aa_a, ad_set: insert(:ad_set, ad_account: aa_a))
      ad_b = insert(:ad, ad_account: aa_b, ad_set: insert(:ad_set, ad_account: aa_b))

      {:ok, e_a} =
        Embeddings.upsert(%{
          kind: "ad",
          ref_id: ad_a.id,
          embedding: random_vector(),
          content_hash: Embeddings.hash_content("a")
        })

      {:ok, e_b} =
        Embeddings.upsert(%{
          kind: "ad",
          ref_id: ad_b.id,
          embedding: random_vector(),
          content_hash: Embeddings.hash_content("b")
        })

      kept = Embeddings.tenant_filter_results([e_a, e_b], mc_a.user)
      assert Enum.map(kept, & &1.id) == [e_a.id]

      kept_b = Embeddings.tenant_filter_results([e_a, e_b], mc_b.user)
      assert Enum.map(kept_b, & &1.id) == [e_b.id]
    end

    test "drops finding rows whose ref_id belongs to another tenant" do
      mc_a = insert(:meta_connection)
      mc_b = insert(:meta_connection)

      aa_a = insert(:ad_account, meta_connection: mc_a)
      aa_b = insert(:ad_account, meta_connection: mc_b)

      ad_a = insert(:ad, ad_account: aa_a, ad_set: insert(:ad_set, ad_account: aa_a))
      ad_b = insert(:ad, ad_account: aa_b, ad_set: insert(:ad_set, ad_account: aa_b))

      f_a = insert(:finding, ad_id: ad_a.id, ad_account_id: aa_a.id)
      f_b = insert(:finding, ad_id: ad_b.id, ad_account_id: aa_b.id)

      {:ok, e_a} =
        Embeddings.upsert(%{
          kind: "finding",
          ref_id: f_a.id,
          embedding: random_vector(),
          content_hash: Embeddings.hash_content("fa")
        })

      {:ok, e_b} =
        Embeddings.upsert(%{
          kind: "finding",
          ref_id: f_b.id,
          embedding: random_vector(),
          content_hash: Embeddings.hash_content("fb")
        })

      kept = Embeddings.tenant_filter_results([e_a, e_b], mc_a.user)
      assert Enum.map(kept, & &1.id) == [e_a.id]
    end

    test "passes through doc_chunk rows for any user (admin-curated, global)" do
      mc = insert(:meta_connection)

      {:ok, doc} =
        Embeddings.upsert(%{
          kind: "doc_chunk",
          ref_id: Ecto.UUID.generate(),
          embedding: random_vector(),
          content_hash: Embeddings.hash_content("help")
        })

      kept = Embeddings.tenant_filter_results([doc], mc.user)
      assert Enum.map(kept, & &1.id) == [doc.id]
    end
  end

  describe "scrub_for_user/1" do
    test "nils out content_excerpt for ad-kind rows" do
      row = %Embedding{kind: "ad", content_excerpt: "ad copy with PII"}
      assert [%Embedding{kind: "ad", content_excerpt: nil}] = Embeddings.scrub_for_user([row])
    end

    test "nils out content_excerpt for finding-kind rows" do
      row = %Embedding{kind: "finding", content_excerpt: "finding text"}

      assert [%Embedding{kind: "finding", content_excerpt: nil}] =
               Embeddings.scrub_for_user([row])
    end

    test "preserves content_excerpt for doc_chunk rows" do
      row = %Embedding{kind: "doc_chunk", content_excerpt: "help docs"}

      assert [%Embedding{kind: "doc_chunk", content_excerpt: "help docs"}] =
               Embeddings.scrub_for_user([row])
    end

    test "returns [] for empty input" do
      assert [] = Embeddings.scrub_for_user([])
    end

    test "preserves order and scrubs only ad/finding kinds in a mixed list" do
      ad = %Embedding{kind: "ad", content_excerpt: "ad", ref_id: "1"}
      doc = %Embedding{kind: "doc_chunk", content_excerpt: "doc", ref_id: "2"}
      finding = %Embedding{kind: "finding", content_excerpt: "finding", ref_id: "3"}

      assert [
               %Embedding{kind: "ad", content_excerpt: nil, ref_id: "1"},
               %Embedding{kind: "doc_chunk", content_excerpt: "doc", ref_id: "2"},
               %Embedding{kind: "finding", content_excerpt: nil, ref_id: "3"}
             ] = Embeddings.scrub_for_user([ad, doc, finding])
    end
  end
end
