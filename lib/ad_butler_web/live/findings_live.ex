defmodule AdButlerWeb.FindingsLive do
  @moduledoc """
  LiveView for browsing budget-leak findings.

  Lists findings scoped to the authenticated user, with filters for severity,
  kind, and ad account. Pagination and filters push URL patches to keep state
  in the URL. Streams findings to avoid unbounded assigns.
  """

  use AdButlerWeb, :live_view

  import AdButlerWeb.FindingHelpers

  alias AdButler.Ads
  alias AdButler.Analytics

  @per_page 50
  @valid_severities ~w(low medium high)
  @valid_kinds ~w(dead_spend cpa_explosion bot_traffic placement_drag stalled_learning creative_fatigue)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream(:findings, [])
      |> assign(:active_nav, :findings)
      |> assign(:filter_severity, nil)
      |> assign(:filter_kind, nil)
      |> assign(:filter_ad_account_id, nil)
      |> assign(:ad_accounts_list, [])
      |> assign(:finding_count, 0)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)

    if connected?(socket), do: send(self(), :reload_on_reconnect)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    severity = if params["severity"] in @valid_severities, do: params["severity"]
    kind = if params["kind"] in @valid_kinds, do: params["kind"]

    ad_account_id =
      case Ecto.UUID.cast(params["ad_account_id"] || "") do
        {:ok, uuid} -> uuid
        :error -> nil
      end

    page = parse_page(params["page"])

    socket =
      socket
      |> assign(:filter_severity, severity)
      |> assign(:filter_kind, kind)
      |> assign(:filter_ad_account_id, ad_account_id)
      |> assign(:page, page)

    if connected?(socket) do
      {:noreply, load_findings(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_changed", params, socket) do
    severity = if params["severity"] in @valid_severities, do: params["severity"]
    kind = if params["kind"] in @valid_kinds, do: params["kind"]

    query =
      %{}
      |> maybe_put("severity", severity)
      |> maybe_put("kind", kind)
      |> maybe_put("ad_account_id", params["ad_account_id"])

    {:noreply, push_patch(socket, to: ~p"/findings?#{query}")}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    query =
      %{}
      |> maybe_put("severity", socket.assigns.filter_severity)
      |> maybe_put("kind", socket.assigns.filter_kind)
      |> maybe_put("ad_account_id", socket.assigns.filter_ad_account_id)
      |> Map.put("page", page)

    {:noreply, push_patch(socket, to: ~p"/findings?#{query}")}
  end

  @impl true
  def handle_info(:reload_on_reconnect, socket) do
    ad_accounts = Ads.list_ad_accounts(socket.assigns.current_user)

    socket =
      socket
      |> assign(:ad_accounts_list, ad_accounts)
      |> load_findings()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-gray-900 mb-4">Findings</h1>
        <p class="text-sm text-gray-600">
          {@finding_count} {if @finding_count == 1, do: "finding", else: "findings"}
        </p>
      </div>

      <form phx-change="filter_changed" class="mb-6 flex flex-wrap gap-4">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Severity</label>
          <select
            name="severity"
            class="block w-36 rounded-md border border-gray-300 bg-white py-2 pl-3 pr-3 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All</option>
            <option value="high" selected={@filter_severity == "high"}>High</option>
            <option value="medium" selected={@filter_severity == "medium"}>Medium</option>
            <option value="low" selected={@filter_severity == "low"}>Low</option>
          </select>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Kind</label>
          <select
            name="kind"
            class="block w-48 rounded-md border border-gray-300 bg-white py-2 pl-3 pr-3 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All</option>
            <option value="dead_spend" selected={@filter_kind == "dead_spend"}>Dead Spend</option>
            <option value="cpa_explosion" selected={@filter_kind == "cpa_explosion"}>
              CPA Explosion
            </option>
            <option value="bot_traffic" selected={@filter_kind == "bot_traffic"}>Bot Traffic</option>
            <option value="placement_drag" selected={@filter_kind == "placement_drag"}>
              Placement Drag
            </option>
            <option value="stalled_learning" selected={@filter_kind == "stalled_learning"}>
              Stalled Learning
            </option>
            <option value="creative_fatigue" selected={@filter_kind == "creative_fatigue"}>
              Creative Fatigue
            </option>
          </select>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Ad Account</label>
          <select
            name="ad_account_id"
            class="block w-48 rounded-md border border-gray-300 bg-white py-2 pl-3 pr-3 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All accounts</option>
            <option
              :for={aa <- @ad_accounts_list}
              value={aa.id}
              selected={@filter_ad_account_id == aa.id}
            >
              {aa.name}
            </option>
          </select>
        </div>
      </form>

      <div class="bg-white shadow rounded-lg">
        <div :if={@finding_count == 0} class="px-4 py-12 text-center">
          <p class="text-gray-500">No findings match your filters.</p>
        </div>

        <div :if={@finding_count > 0}>
          <.table id="findings" rows={@streams.findings}>
            <:col :let={{_dom_id, f}} label="Finding">
              <.link
                navigate={~p"/findings/#{f.id}"}
                class="text-blue-600 hover:text-blue-800 font-medium"
              >
                {f.title}
              </.link>
            </:col>
            <:col :let={{_dom_id, f}} label="Kind">
              {kind_label(f.kind)}
            </:col>
            <:col :let={{_dom_id, f}} label="Severity">
              <span class={severity_badge_class(f.severity)}>
                {String.capitalize(f.severity)}
              </span>
            </:col>
            <:col :let={{_dom_id, f}} label="Detected">
              {Calendar.strftime(f.inserted_at, "%b %d, %Y")}
            </:col>
          </.table>
          <.pagination page={@page} total_pages={@total_pages} />
        </div>
      </div>
    </div>
    """
  end

  defp load_findings(socket) do
    current_user = socket.assigns.current_user

    opts =
      [page: socket.assigns.page, per_page: @per_page]
      |> maybe_put(:severity, socket.assigns.filter_severity)
      |> maybe_put(:kind, socket.assigns.filter_kind)
      |> maybe_put(:ad_account_id, socket.assigns.filter_ad_account_id)

    {findings, total} = Analytics.paginate_findings(current_user, opts)
    total_pages = max(1, ceil(total / @per_page))

    socket
    |> stream(:findings, findings, reset: true)
    |> assign(:finding_count, total)
    |> assign(:total_pages, total_pages)
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp maybe_put(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)
end
