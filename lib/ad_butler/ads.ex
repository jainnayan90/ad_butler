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
  alias AdButler.Ads.{Ad, AdAccount, AdSet, Campaign, Creative, Insight}
  alias AdButler.Repo

  # ---------------------------------------------------------------------------
  # Security boundary: all user-facing queries pass through scope/2
  # ---------------------------------------------------------------------------

  # Applies a struct/2 select that excludes heavy JSON columns from list queries.
  defp select_list_fields(queryable, schema, exclude \\ [:raw_jsonb]) do
    fields = schema.__schema__(:fields) -- exclude
    select(queryable, [x], struct(x, ^fields))
  end

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
    rows =
      AdAccount
      |> scope_ad_account(mc_ids)
      |> limit(200)
      |> select_list_fields(AdAccount)
      |> Repo.all()

    if length(rows) == 200 do
      Logger.warning("list_ad_accounts truncated at 200 rows",
        meta_connection_count: length(mc_ids)
      )
    end

    rows
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
      |> select_list_fields(AdAccount)
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

  @doc "UNSAFE — returns all active ad accounts regardless of tenant. Internal scheduler use only."
  @spec list_ad_accounts_internal() :: [AdAccount.t()]
  def list_ad_accounts_internal do
    Repo.all(from aa in AdAccount, where: aa.status == "ACTIVE")
  end

  @doc "Returns all `AdAccount` records whose `meta_connection_id` is in `mc_ids`. Internal scheduler use only — no user scope."
  @spec list_ad_accounts_by_mc_ids([binary()]) :: [AdAccount.t()]
  def list_ad_accounts_by_mc_ids(mc_ids) when is_list(mc_ids) do
    AdAccount
    |> where([aa], aa.meta_connection_id in ^mc_ids)
    |> select_list_fields(AdAccount)
    |> Repo.all()
  end

  @doc "Returns all ad account IDs belonging to the given MetaConnection IDs."
  @spec list_ad_account_ids_for_mc_ids([binary()]) :: [binary()]
  def list_ad_account_ids_for_mc_ids([]), do: []

  def list_ad_account_ids_for_mc_ids(mc_ids) do
    Repo.all(from aa in AdAccount, where: aa.meta_connection_id in ^mc_ids, select: aa.id)
  end

  @doc "Returns all ad account IDs for `user` in a single SQL query via subquery."
  @spec list_ad_account_ids_for_user(Accounts.User.t()) :: [binary()]
  def list_ad_account_ids_for_user(%Accounts.User{} = user) do
    mc_ids_query = Accounts.list_meta_connection_ids_query(user)

    Repo.all(
      from aa in AdAccount, where: aa.meta_connection_id in subquery(mc_ids_query), select: aa.id
    )
  end

  @doc "Streams active AdAccounts for internal scheduler use. Must be called inside a transaction."
  @spec stream_active_ad_accounts() :: Enum.t()
  def stream_active_ad_accounts do
    from(aa in AdAccount, where: aa.status == "ACTIVE")
    |> Repo.stream(max_rows: 500)
  end

  @doc "Streams active ad accounts inside a transaction and passes the stream to `fun`. Returns `{:ok, fun_result} | {:error, reason}`."
  @spec stream_ad_accounts_and_run((Enumerable.t() -> any()), keyword()) ::
          {:ok, any()} | {:error, any()}
  def stream_ad_accounts_and_run(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(5))
    Repo.transaction(fn -> fun.(stream_active_ad_accounts()) end, timeout: timeout)
  end

  @doc "UNSAFE — queries ads by `ad_account_id` without tenant scope. Callers must verify ownership of `ad_account_id` before calling."
  @spec unsafe_get_ad_meta_id_map(binary()) :: %{String.t() => binary()}
  def unsafe_get_ad_meta_id_map(ad_account_id) do
    Ad
    |> where([a], a.ad_account_id == ^ad_account_id)
    |> select([a], {a.meta_id, a.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Returns the `AdAccount` matching `(meta_connection_id, meta_id)`, or `nil`."
  @spec get_ad_account_by_meta_id(binary(), binary()) :: AdAccount.t() | nil
  def get_ad_account_by_meta_id(meta_connection_id, meta_id) do
    Repo.get_by(AdAccount, meta_connection_id: meta_connection_id, meta_id: meta_id)
  end

  @doc """
  Inserts or updates an `AdAccount` for `meta_connection_id`, keyed on `(meta_connection_id, meta_id)`.

  **Caller MUST verify `meta_connection_id` ownership before calling.**
  Never invoke from a controller or LiveView with a user-supplied UUID — use the scoped
  context functions (`get_ad_account!/2`) to establish ownership first.
  """
  @spec upsert_ad_account(binary(), map()) :: {:ok, AdAccount.t()} | {:error, Ecto.Changeset.t()}
  def upsert_ad_account(meta_connection_id, attrs) when is_binary(meta_connection_id) do
    %AdAccount{meta_connection_id: meta_connection_id}
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
    |> select_list_fields(Campaign)
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
      |> select_list_fields(Campaign)
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
    |> select_list_fields(AdSet, [:raw_jsonb, :targeting_jsonb])
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
      |> select_list_fields(AdSet, [:raw_jsonb, :targeting_jsonb])
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
    |> select_list_fields(Ad)
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
      |> select_list_fields(Ad)
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

  # ---------------------------------------------------------------------------
  # Insights
  # ---------------------------------------------------------------------------

  @doc """
  Bulk-upserts a list of insight rows into `insights_daily`.

  Each map in `rows` must include at minimum `:ad_id` and `:date_start`. All
  numeric fields are assumed already normalised to cents/integers by the caller.
  Returns `{:ok, count}` on success or `{:error, term()}` on failure.
  """
  @spec bulk_upsert_insights([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def bulk_upsert_insights(rows) when is_list(rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _} =
      Repo.insert_all(Insight, entries,
        on_conflict:
          {:replace,
           [
             :spend_cents,
             :impressions,
             :clicks,
             :reach_count,
             :frequency,
             :conversions,
             :conversion_value_cents,
             :ctr_numeric,
             :cpm_cents,
             :cpc_cents,
             :cpa_cents,
             :by_placement_jsonb,
             :by_age_gender_jsonb,
             :updated_at
           ]},
        conflict_target: [:ad_id, :date_start]
      )

    {:ok, count}
  rescue
    e in Postgrex.Error ->
      Logger.error("bulk_upsert_insights failed", reason: Exception.message(e))
      {:error, :upsert_failed}
  end

  @doc "UNSAFE — queries the `ad_insights_7d` view directly by `ad_id` without tenant scope. Caller must verify `ad_id` ownership before calling."
  @spec unsafe_get_7d_insights(binary()) :: {:ok, map() | nil}
  def unsafe_get_7d_insights(ad_id) do
    row =
      Repo.one(
        from v in "ad_insights_7d",
          where: v.ad_id == type(^ad_id, :binary_id),
          select: %{
            ad_id: v.ad_id,
            spend_cents: type(v.spend_cents, :integer),
            impressions: type(v.impressions, :integer),
            clicks: type(v.clicks, :integer),
            conversions: type(v.conversions, :integer),
            conversion_value_cents: type(v.conversion_value_cents, :integer),
            ctr: v.ctr,
            cpm_cents: type(v.cpm_cents, :integer),
            cpc_cents: type(v.cpc_cents, :integer),
            cpa_cents: type(v.cpa_cents, :integer)
          }
      )

    {:ok, row}
  end

  @doc "UNSAFE — queries the `ad_insights_30d` view directly by `ad_id` without tenant scope. Caller must verify `ad_id` ownership before calling."
  @spec unsafe_get_30d_baseline(binary()) :: {:ok, map() | nil}
  def unsafe_get_30d_baseline(ad_id) do
    row =
      Repo.one(
        from v in "ad_insights_30d",
          where: v.ad_id == type(^ad_id, :binary_id),
          select: %{
            ad_id: v.ad_id,
            spend_cents: type(v.spend_cents, :integer),
            impressions: type(v.impressions, :integer),
            clicks: type(v.clicks, :integer),
            conversions: type(v.conversions, :integer),
            conversion_value_cents: type(v.conversion_value_cents, :integer),
            ctr: v.ctr,
            cpm_cents: type(v.cpm_cents, :integer),
            cpc_cents: type(v.cpc_cents, :integer),
            cpa_cents: type(v.cpa_cents, :integer)
          }
      )

    {:ok, row}
  end

  @doc """
  UNSAFE — no tenant scope. Returns `insights_daily` rows for ads in `ad_account_id`
  within the past `hours` hours. Internal auditor use only.
  """
  @spec unsafe_list_insights_since(binary(), pos_integer()) :: [map()]
  def unsafe_list_insights_since(ad_account_id, hours) do
    cutoff_date = DateTime.to_date(DateTime.add(DateTime.utc_now(), -hours, :hour))

    Repo.all(
      from i in "insights_daily",
        join: a in Ad,
        on: i.ad_id == a.id,
        where: a.ad_account_id == ^ad_account_id and i.date_start >= ^cutoff_date,
        select: %{
          ad_id: a.id,
          ad_set_id: a.ad_set_id,
          spend_cents: i.spend_cents,
          impressions: i.impressions,
          clicks: i.clicks,
          conversions: i.conversions,
          reach_count: i.reach_count,
          ctr_numeric: i.ctr_numeric,
          by_placement_jsonb: i.by_placement_jsonb
        }
    )
  end

  @doc "UNSAFE — no tenant scope. Returns `%{ad_id => ad_set_id}` for all ads in the account. Internal auditor use only."
  @spec unsafe_build_ad_set_map(binary()) :: %{binary() => binary() | nil}
  def unsafe_build_ad_set_map(ad_account_id) do
    Repo.all(from a in Ad, where: a.ad_account_id == ^ad_account_id, select: {a.id, a.ad_set_id})
    |> Map.new()
  end

  @doc "UNSAFE — no tenant scope. Returns ids of AdSets in LEARNING status for >7 days. Internal auditor use only."
  @spec unsafe_list_stalled_learning_ad_set_ids(binary()) :: MapSet.t()
  def unsafe_list_stalled_learning_ad_set_ids(ad_account_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 24, :hour)

    Repo.all(
      from s in AdSet,
        where:
          s.ad_account_id == ^ad_account_id and
            fragment("?->>'effective_status' = 'LEARNING'", s.raw_jsonb) and
            s.updated_at < ^cutoff,
        select: s.id
    )
    |> MapSet.new()
  end

  @doc """
  UNSAFE — no tenant scope. Returns `%{ad_id => %{cpa_cents: integer(), ...}}` from the
  `ad_insights_30d` view for the given ad IDs in one query. Internal auditor use only.
  """
  @spec unsafe_list_30d_baselines([binary()]) :: %{binary() => map()}
  def unsafe_list_30d_baselines(ad_ids) when is_list(ad_ids) do
    Repo.all(
      from v in "ad_insights_30d",
        where: v.ad_id in ^Enum.map(ad_ids, &Ecto.UUID.dump!/1),
        select: %{
          ad_id: type(v.ad_id, :binary_id),
          spend_cents: type(v.spend_cents, :integer),
          impressions: type(v.impressions, :integer),
          clicks: type(v.clicks, :integer),
          conversions: type(v.conversions, :integer),
          cpa_cents: type(v.cpa_cents, :integer)
        }
    )
    |> Map.new(&{&1.ad_id, &1})
  end

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
