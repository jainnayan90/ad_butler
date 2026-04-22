defmodule AdButler.Ads do
  @moduledoc false
  import Ecto.Query

  require Logger

  alias AdButler.Accounts
  alias AdButler.Accounts.{MetaConnection, User}
  alias AdButler.Ads.{Ad, AdAccount, AdSet, Campaign, Creative}
  alias AdButler.Repo

  # ---------------------------------------------------------------------------
  # Security boundary: all user-facing queries pass through scope/2
  # ---------------------------------------------------------------------------

  # Issues one extra SELECT to fetch connection IDs before the main query (2 round-trips
  # per scoped call). Acceptable for single lookups. If calling multiple scoped functions
  # in the same request, hoist list_meta_connection_ids_for_user/1 to the caller.
  defp scope_ad_account(queryable, %User{} = user) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)
    from aa in queryable, where: aa.meta_connection_id in ^mc_ids
  end

  defp scope(queryable, %User{} = user) do
    mc_ids = Accounts.list_meta_connection_ids_for_user(user)

    from q in queryable,
      join: aa in AdAccount,
      on: q.ad_account_id == aa.id,
      where: aa.meta_connection_id in ^mc_ids
  end

  # ---------------------------------------------------------------------------
  # AdAccount
  # ---------------------------------------------------------------------------

  @spec list_ad_accounts(User.t()) :: [AdAccount.t()]
  def list_ad_accounts(%User{} = user) do
    AdAccount
    |> scope_ad_account(user)
    |> Repo.all()
  end

  @spec get_ad_account!(User.t(), binary()) :: AdAccount.t()
  def get_ad_account!(%User{} = user, id) do
    AdAccount
    |> scope_ad_account(user)
    |> Repo.get!(id)
  end

  @doc "UNSAFE — bypasses tenant scope. Use only in internal sync pipeline, never in user-facing controllers."
  @spec unsafe_get_ad_account_for_sync(binary()) :: AdAccount.t() | nil
  def unsafe_get_ad_account_for_sync(id), do: Repo.get(AdAccount, id)

  @spec get_ad_account_by_meta_id(binary(), binary()) :: AdAccount.t() | nil
  def get_ad_account_by_meta_id(meta_connection_id, meta_id) do
    Repo.get_by(AdAccount, meta_connection_id: meta_connection_id, meta_id: meta_id)
  end

  @spec upsert_ad_account(MetaConnection.t(), map()) ::
          {:ok, AdAccount.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ad_account(%MetaConnection{} = connection, attrs) do
    %AdAccount{meta_connection_id: connection.id}
    |> AdAccount.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:name, :currency, :timezone_name, :status, :last_synced_at, :raw_jsonb, :updated_at]},
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
    now = DateTime.utc_now()

    entries =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:ad_account_id, ad_account.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    entries = bulk_validate(entries, Campaign)

    Repo.insert_all(
      Campaign,
      entries,
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
    now = DateTime.utc_now()

    entries =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:ad_account_id, ad_account.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    entries = bulk_validate(entries, AdSet)

    Repo.insert_all(
      AdSet,
      entries,
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

  @spec list_campaigns(User.t(), keyword()) :: [Campaign.t()]
  def list_campaigns(%User{} = user, opts \\ []) do
    Campaign
    |> scope(user)
    |> apply_campaign_filters(opts)
    |> Repo.all()
  end

  @spec get_campaign!(User.t(), binary()) :: Campaign.t()
  def get_campaign!(%User{} = user, id) do
    Campaign
    |> scope(user)
    |> Repo.get!(id)
  end

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

  @spec list_ad_sets(User.t(), keyword()) :: [AdSet.t()]
  def list_ad_sets(%User{} = user, opts \\ []) do
    AdSet
    |> scope(user)
    |> apply_ad_set_filters(opts)
    |> Repo.all()
  end

  @spec get_ad_set!(User.t(), binary()) :: AdSet.t()
  def get_ad_set!(%User{} = user, id) do
    AdSet
    |> scope(user)
    |> Repo.get!(id)
  end

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

  @spec list_ads(User.t(), keyword()) :: [Ad.t()]
  def list_ads(%User{} = user, opts \\ []) do
    Ad
    |> scope(user)
    |> apply_ad_filters(opts)
    |> Repo.all()
  end

  @spec get_ad!(User.t(), binary()) :: Ad.t()
  def get_ad!(%User{} = user, id) do
    Ad
    |> scope(user)
    |> Repo.get!(id)
  end

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

  @doc false
  @spec bulk_upsert_ads(AdAccount.t(), [map()]) ::
          {non_neg_integer(), [%{id: binary(), meta_id: binary()}]}
  def bulk_upsert_ads(%AdAccount{} = ad_account, attrs_list) do
    now = DateTime.utc_now()

    entries =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:ad_account_id, ad_account.id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    entries = bulk_validate(entries, Ad)

    Repo.insert_all(
      Ad,
      entries,
      on_conflict: {:replace, [:name, :status, :raw_jsonb, :updated_at]},
      conflict_target: [:ad_account_id, :meta_id],
      returning: [:id, :meta_id]
    )
  end

  defp apply_ad_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:ad_account_id, id}, q -> where(q, [a], a.ad_account_id == ^id)
      {:ad_set_id, id}, q -> where(q, [a], a.ad_set_id == ^id)
      _, q -> q
    end)
  end

  defp bulk_validate(attrs_list, schema_mod) do
    known_fields = schema_mod.__schema__(:fields)

    {valid, invalid} =
      Enum.split_with(attrs_list, fn attrs ->
        schema_mod.changeset(struct(schema_mod), attrs).valid?
      end)

    if invalid != [] do
      meta_ids = Enum.map(invalid, & &1[:meta_id])

      Logger.warning("bulk_validate: dropped invalid rows",
        count: length(invalid),
        meta_ids: meta_ids
      )
    end

    Enum.map(valid, &Map.take(&1, known_fields))
  end

  # ---------------------------------------------------------------------------
  # Creative
  # ---------------------------------------------------------------------------

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
