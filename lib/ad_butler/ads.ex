defmodule AdButler.Ads do
  @moduledoc """
  Context for ad data — ad accounts, campaigns, ad sets, ads, and creatives.

  All user-facing queries are scoped to the requesting user's `MetaConnection` IDs so
  one user can never access another's data. Bulk upsert functions bypass changeset
  validation for performance; callers are responsible for valid attrs.
  """
  import Ecto.Query

  require Logger

  alias AdButler.Accounts
  alias AdButler.Accounts.User
  alias AdButler.Ads.{Ad, AdAccount, AdSet, Campaign, Creative}
  alias AdButler.Repo

  # ---------------------------------------------------------------------------
  # Security boundary: all user-facing queries pass through scope/2
  # ---------------------------------------------------------------------------

  # Accepts a pre-fetched list of MetaConnection UUIDs. Public list functions call
  # Accounts.list_meta_connection_ids_for_user/1 once and pass the result here,
  # keeping the Accounts call out of the scope helper itself.
  defp scope_ad_account(queryable, mc_ids) when is_list(mc_ids) do
    from aa in queryable, where: aa.meta_connection_id in ^mc_ids
  end

  defp scope(queryable, mc_ids) when is_list(mc_ids) do
    from q in queryable,
      join: aa in AdAccount,
      on: q.ad_account_id == aa.id,
      where: aa.meta_connection_id in ^mc_ids
  end

  # ---------------------------------------------------------------------------
  # AdAccount
  # ---------------------------------------------------------------------------

  @doc "Returns all `AdAccount` records accessible to `user`, or to the given list of MetaConnection UUIDs."
  @spec list_ad_accounts(User.t()) :: [AdAccount.t()]
  def list_ad_accounts(%User{} = user) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    list_ad_accounts(mc_ids)
  end

  @spec list_ad_accounts([binary()]) :: [AdAccount.t()]
  def list_ad_accounts(mc_ids) when is_list(mc_ids) do
    AdAccount
    |> scope_ad_account(mc_ids)
    |> Repo.all()
  end

  @doc """
  Returns a page of `AdAccount` records for `user` and the total count.

  Options:
  - `:page` — 1-based page number (default: `1`)
  - `:per_page` — records per page (default: `50`)
  """
  @spec paginate_ad_accounts(User.t(), keyword()) :: {[AdAccount.t()], non_neg_integer()}
  def paginate_ad_accounts(%User{} = user, opts \\ []) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base = scope_ad_account(AdAccount, mc_ids)
    total = Repo.aggregate(base, :count)

    items =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  @doc "Returns the `AdAccount` with `id` scoped to `user`. Raises if not found or not owned."
  @spec get_ad_account!(User.t(), binary()) :: AdAccount.t()
  def get_ad_account!(%User{} = user, id) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)

    AdAccount
    |> scope_ad_account(mc_ids)
    |> Repo.get!(id)
  end

  @doc "UNSAFE — bypasses tenant scope. Use only in internal sync pipeline, never in user-facing controllers."
  @spec unsafe_get_ad_account_for_sync(binary()) :: AdAccount.t() | nil
  def unsafe_get_ad_account_for_sync(id), do: Repo.get(AdAccount, id)

  @doc "Returns the `AdAccount` matching `(meta_connection_id, meta_id)`, or `nil`."
  @spec get_ad_account_by_meta_id(binary(), binary()) :: AdAccount.t() | nil
  def get_ad_account_by_meta_id(meta_connection_id, meta_id) do
    Repo.get_by(AdAccount, meta_connection_id: meta_connection_id, meta_id: meta_id)
  end

  @doc "Inserts or updates an `AdAccount` for `connection`, keyed on `(meta_connection_id, meta_id)`."
  @spec upsert_ad_account(AdButler.Accounts.MetaConnection.t(), map()) ::
          {:ok, AdAccount.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ad_account(%AdButler.Accounts.MetaConnection{} = connection, attrs) do
    %AdAccount{meta_connection_id: connection.id}
    |> AdAccount.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :name,
           :currency,
           :timezone_name,
           :status,
           :bm_id,
           :bm_name,
           :last_synced_at,
           :raw_jsonb,
           :updated_at
         ]},
      conflict_target: [:meta_connection_id, :meta_id],
      returning: true
    )
  end

  # ---------------------------------------------------------------------------
  # Campaign
  # ---------------------------------------------------------------------------

  @doc "Bulk upserts campaigns. No changeset validation runs — caller is responsible for valid attrs."
  @spec bulk_upsert_campaigns(AdAccount.t(), [map()]) ::
          {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
  def bulk_upsert_campaigns(%AdAccount{} = ad_account, attrs_list) do
    do_bulk_upsert(Campaign, ad_account.id, attrs_list,
      on_conflict:
        {:replace,
         [
           :name,
           :status,
           :objective,
           :daily_budget_cents,
           :lifetime_budget_cents,
           :raw_jsonb,
           :updated_at
         ]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: [:id, :meta_id]
    )
  end

  @doc "Bulk upserts ad sets. No changeset validation runs — caller is responsible for valid attrs."
  @spec bulk_upsert_ad_sets(AdAccount.t(), [map()]) ::
          {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
  def bulk_upsert_ad_sets(%AdAccount{} = ad_account, attrs_list) do
    do_bulk_upsert(AdSet, ad_account.id, attrs_list,
      on_conflict:
        {:replace,
         [
           :name,
           :status,
           :daily_budget_cents,
           :lifetime_budget_cents,
           :bid_amount_cents,
           :targeting_jsonb,
           :raw_jsonb,
           :updated_at
         ]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: [:id, :meta_id]
    )
  end

  @doc "Returns campaigns accessible to `user` (or directly to `mc_ids`). Supports `:ad_account_id` and `:status` filters."
  @spec list_campaigns(User.t() | [binary()], keyword()) :: [Campaign.t()]
  def list_campaigns(user_or_mc_ids, opts \\ [])

  def list_campaigns(%User{} = user, opts) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    list_campaigns(mc_ids, opts)
  end

  def list_campaigns(mc_ids, opts) when is_list(mc_ids) do
    Campaign
    |> scope(mc_ids)
    |> apply_campaign_filters(opts)
    |> Repo.all()
  end

  @doc """
  Returns a page of campaigns for `user` and the total count matching the filters.

  Options (in addition to filter opts `:ad_account_id`, `:status`):
  - `:page` — 1-based page number (default: `1`)
  - `:per_page` — records per page (default: `50`)
  """
  @spec paginate_campaigns(User.t() | [binary()], keyword()) ::
          {[Campaign.t()], non_neg_integer()}
  def paginate_campaigns(user_or_mc_ids, opts \\ [])

  def paginate_campaigns(%User{} = user, opts) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    paginate_campaigns(mc_ids, opts)
  end

  def paginate_campaigns(mc_ids, opts) when is_list(mc_ids) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base =
      Campaign
      |> scope(mc_ids)
      |> apply_campaign_filters(opts)

    total = Repo.aggregate(base, :count)

    items =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  @doc "Returns the campaign with `id` scoped to `user`. Raises if not found or not owned."
  @spec get_campaign!(User.t(), binary()) :: Campaign.t()
  def get_campaign!(%User{} = user, id) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)

    Campaign
    |> scope(mc_ids)
    |> Repo.get!(id)
  end

  @doc "Inserts or updates a campaign for `ad_account`, keyed on `(ad_account_id, meta_id)`."
  @spec upsert_campaign(AdAccount.t(), map()) ::
          {:ok, Campaign.t()} | {:error, Ecto.Changeset.t()}
  def upsert_campaign(%AdAccount{} = ad_account, attrs) do
    %Campaign{ad_account_id: ad_account.id}
    |> Campaign.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :name,
           :status,
           :objective,
           :daily_budget_cents,
           :lifetime_budget_cents,
           :raw_jsonb,
           :updated_at
         ]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: true
    )
  end

  defp apply_campaign_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:ad_account_id, id}, q -> where(q, [c], c.ad_account_id == ^id)
      {:status, status}, q -> where(q, [c], c.status == ^status)
      _, q -> q
    end)
  end

  # ---------------------------------------------------------------------------
  # AdSet
  # ---------------------------------------------------------------------------

  @doc "Returns ad sets accessible to `user` (or directly to `mc_ids`). Supports `:ad_account_id` and `:campaign_id` filters."
  @spec list_ad_sets(User.t() | [binary()], keyword()) :: [AdSet.t()]
  def list_ad_sets(user_or_mc_ids, opts \\ [])

  def list_ad_sets(%User{} = user, opts) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    list_ad_sets(mc_ids, opts)
  end

  def list_ad_sets(mc_ids, opts) when is_list(mc_ids) do
    AdSet
    |> scope(mc_ids)
    |> apply_ad_set_filters(opts)
    |> Repo.all()
  end

  @doc "Returns the ad set with `id` scoped to `user`. Raises if not found or not owned."
  @spec get_ad_set!(User.t(), binary()) :: AdSet.t()
  def get_ad_set!(%User{} = user, id) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)

    AdSet
    |> scope(mc_ids)
    |> Repo.get!(id)
  end

  @doc "Inserts or updates an ad set for `ad_account`, keyed on `(ad_account_id, meta_id)`."
  @spec upsert_ad_set(AdAccount.t(), map()) ::
          {:ok, AdSet.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ad_set(%AdAccount{} = ad_account, attrs) do
    %AdSet{ad_account_id: ad_account.id}
    |> AdSet.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :name,
           :status,
           :daily_budget_cents,
           :lifetime_budget_cents,
           :bid_amount_cents,
           :targeting_jsonb,
           :raw_jsonb,
           :updated_at
         ]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: true
    )
  end

  @doc """
  Returns a page of ad sets for `user` and the total count matching the filters.

  Options (in addition to filter opts `:ad_account_id`, `:campaign_id`):
  - `:page` — 1-based page number (default: `1`)
  - `:per_page` — records per page (default: `50`)
  """
  @spec paginate_ad_sets(User.t() | [binary()], keyword()) :: {[AdSet.t()], non_neg_integer()}
  def paginate_ad_sets(user_or_mc_ids, opts \\ [])

  def paginate_ad_sets(%User{} = user, opts) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    paginate_ad_sets(mc_ids, opts)
  end

  def paginate_ad_sets(mc_ids, opts) when is_list(mc_ids) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base =
      AdSet
      |> scope(mc_ids)
      |> apply_ad_set_filters(opts)

    total = Repo.aggregate(base, :count)

    items =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  defp apply_ad_set_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:ad_account_id, id}, q -> where(q, [s], s.ad_account_id == ^id)
      {:campaign_id, id}, q -> where(q, [s], s.campaign_id == ^id)
      _, q -> q
    end)
  end

  # ---------------------------------------------------------------------------
  # Ad
  # ---------------------------------------------------------------------------

  @doc "Returns ads accessible to `user` (or directly to `mc_ids`). Supports `:ad_account_id` and `:ad_set_id` filters."
  @spec list_ads(User.t() | [binary()], keyword()) :: [Ad.t()]
  def list_ads(user_or_mc_ids, opts \\ [])

  def list_ads(%User{} = user, opts) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    list_ads(mc_ids, opts)
  end

  def list_ads(mc_ids, opts) when is_list(mc_ids) do
    Ad
    |> scope(mc_ids)
    |> apply_ad_filters(opts)
    |> Repo.all()
  end

  @doc "Returns the ad with `id` scoped to `user`. Raises if not found or not owned."
  @spec get_ad!(User.t(), binary()) :: Ad.t()
  def get_ad!(%User{} = user, id) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)

    Ad
    |> scope(mc_ids)
    |> Repo.get!(id)
  end

  @doc "Inserts or updates an ad for `ad_account`, keyed on `(ad_account_id, meta_id)`."
  @spec upsert_ad(AdAccount.t(), map()) ::
          {:ok, Ad.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ad(%AdAccount{} = ad_account, attrs) do
    %Ad{ad_account_id: ad_account.id}
    |> Ad.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :status, :raw_jsonb, :updated_at]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: true
    )
  end

  @doc "Bulk upserts ads. No changeset validation runs — caller is responsible for valid attrs."
  @spec bulk_upsert_ads(AdAccount.t(), [map()]) ::
          {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
  def bulk_upsert_ads(%AdAccount{} = ad_account, attrs_list) do
    do_bulk_upsert(Ad, ad_account.id, attrs_list,
      on_conflict: {:replace, [:name, :status, :raw_jsonb, :updated_at]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: [:id, :meta_id]
    )
  end

  defp do_bulk_upsert(schema, ad_account_id, attrs_list, insert_opts) do
    now = DateTime.utc_now()

    entries =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:ad_account_id, ad_account_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    entries = bulk_strip_and_filter(entries, schema)
    Repo.insert_all(schema, entries, insert_opts)
  end

  @doc """
  Returns a page of ads for `user` and the total count matching the filters.

  Options (in addition to filter opts `:ad_account_id`, `:ad_set_id`):
  - `:page` — 1-based page number (default: `1`)
  - `:per_page` — records per page (default: `50`)
  """
  @spec paginate_ads(User.t() | [binary()], keyword()) :: {[Ad.t()], non_neg_integer()}
  def paginate_ads(user_or_mc_ids, opts \\ [])

  def paginate_ads(%User{} = user, opts) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    paginate_ads(mc_ids, opts)
  end

  def paginate_ads(mc_ids, opts) when is_list(mc_ids) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base =
      Ad
      |> scope(mc_ids)
      |> apply_ad_filters(opts)

    total = Repo.aggregate(base, :count)

    items =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  defp apply_ad_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:ad_account_id, id}, q -> where(q, [a], a.ad_account_id == ^id)
      {:ad_set_id, id}, q -> where(q, [a], a.ad_set_id == ^id)
      _, q -> q
    end)
  end

  defp bulk_strip_and_filter(attrs_list, schema_mod) do
    known_fields = schema_mod.__schema__(:fields)
    required = schema_mod.required_fields()

    {valid, dropped} =
      Enum.split_with(attrs_list, fn attrs ->
        Enum.all?(required, &(not is_nil(Map.get(attrs, &1))))
      end)

    if dropped != [] do
      meta_ids = Enum.map(dropped, & &1[:meta_id])

      Logger.warning("bulk_strip_and_filter: dropped rows missing required fields",
        count: length(dropped),
        meta_ids: meta_ids
      )
    end

    Enum.map(valid, &Map.take(&1, known_fields))
  end

  # ---------------------------------------------------------------------------
  # Creative
  # ---------------------------------------------------------------------------

  @doc "Inserts or updates a creative for `ad_account`, keyed on `(ad_account_id, meta_id)`."
  @spec upsert_creative(AdAccount.t(), map()) ::
          {:ok, Creative.t()} | {:error, Ecto.Changeset.t()}
  def upsert_creative(%AdAccount{} = ad_account, attrs) do
    %Creative{ad_account_id: ad_account.id}
    |> Creative.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :asset_specs_jsonb, :raw_jsonb, :updated_at]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: true
    )
  end
end
