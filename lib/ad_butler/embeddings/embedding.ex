defmodule AdButler.Embeddings.Embedding do
  @moduledoc """
  Schema for one stored embedding vector keyed by `(kind, ref_id)`.

  `kind` is one of `"ad"`, `"finding"`, or `"doc_chunk"` (CHECK constraint
  enforced at the database). `ref_id` points at the source row whose content
  produced this embedding — `ad_id` for ads, `finding_id` for findings, or a
  generated UUID for help-doc chunks (no foreign key by design — embedding
  rows survive source deletion until the next backfill cycle reaps them).

  `content_hash` is a SHA-256 of the source text used at embedding time. The
  refresh worker re-embeds only when the hash differs from a freshly-computed
  hash on the latest source content, avoiding repeated calls to the OpenAI
  embeddings endpoint for unchanged ads.

  `content_excerpt` is a plaintext snippet of the source content stored for
  debugging and similarity-result rendering.

  PII handling rules:

    * `kind` ∈ `{"ad", "finding"}` — source text is advertiser-typed
      (ad name, creative name, finding title/body). It can carry third-party
      PII (customer names mentioned in ad copy, audience descriptors,
      campaign codenames). User-facing surfaces MUST drop `content_excerpt`
      before render, or replace it with a tenant-scoped re-fetch of the
      source row. Never display this field directly in chat or LiveView UI.
    * `kind == "doc_chunk"` — admin-curated help content, exempt; safe to
      render `content_excerpt` directly.

  User-typed conversation content (Week 9 chat history) does NOT belong
  here. It belongs in a separate Cloak-encrypted kind whose schema enforces
  encryption at rest.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(ad finding doc_chunk)

  schema "embeddings" do
    field :kind, :string
    field :ref_id, :binary_id
    field :embedding, Pgvector.Ecto.Vector
    field :content_hash, :string
    field :content_excerpt, :string
    field :metadata, :map

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Returns the list of valid kind strings."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @required [:kind, :ref_id, :embedding, :content_hash]
  @optional [:content_excerpt, :metadata]

  @doc "Builds a changeset for an embedding row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(embedding, attrs) do
    embedding
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:content_hash, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:kind, :ref_id])
  end
end
