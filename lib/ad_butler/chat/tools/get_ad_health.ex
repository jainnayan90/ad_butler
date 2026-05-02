defmodule AdButler.Chat.Tools.GetAdHealth do
  @moduledoc """
  Read tool — returns the current health snapshot for one of the user's
  ads (status, fatigue + leak scores, latest finding summary).

  Re-scopes the LLM-supplied `ad_id` through `Ads.fetch_ad/2` so a
  cross-tenant id is silently rejected (`{:error, :not_found}`) — the tool
  must never leak ad existence on probe.

  Payload is capped at ~4 KB JSON; tests assert.
  """

  use Jido.Action,
    name: "get_ad_health",
    description: "Diagnose one ad: status, fatigue + leak scores, latest finding summary.",
    schema: [
      ad_id: [type: :string, required: true, doc: "UUID of the ad to inspect."]
    ]

  alias AdButler.Ads
  alias AdButler.Analytics
  alias AdButler.Chat.Tools.Helpers

  @latest_findings 3
  @fatigue_factors_excerpt_chars 400

  @doc """
  Runs the tool. `context` MUST carry `:session_context.user_id` so tool
  re-scoping uses the correct user. Returns `{:ok, payload}` on success
  or `{:error, :not_found}` on cross-tenant / missing ad.
  """
  @impl true
  def run(%{ad_id: ad_id}, context) when is_binary(ad_id) do
    case Helpers.context_user(context) do
      {:ok, user} ->
        with {:ok, ad} <- Ads.fetch_ad(user, ad_id) do
          {:ok, build_payload(ad)}
        end

      {:error, _} = err ->
        err
    end
  end

  defp build_payload(ad) do
    health = Analytics.unsafe_get_latest_health_score(ad.id)

    findings =
      ad.id
      |> Analytics.list_open_findings_for_ad(limit: @latest_findings)
      |> Enum.map(&summarise_finding/1)

    %{
      ad_id: ad.id,
      name: ad.name,
      status: ad.status,
      fatigue_score:
        Helpers.decimal_to_float(Helpers.maybe_payload_field(health, :fatigue_score)),
      leak_score: Helpers.decimal_to_float(Helpers.maybe_payload_field(health, :leak_score)),
      latest_findings: findings,
      latest_finding_summary: summarise_top_finding(findings),
      fatigue_factors_excerpt:
        truncate(
          Helpers.maybe_payload_field(health, :fatigue_factors),
          @fatigue_factors_excerpt_chars
        ),
      computed_at: Helpers.maybe_payload_field(health, :computed_at)
    }
  end

  defp summarise_finding(f) do
    %{
      id: f.id,
      kind: f.kind,
      severity: f.severity,
      title: f.title
    }
  end

  defp summarise_top_finding([]), do: nil

  defp summarise_top_finding([%{title: title, severity: sev, kind: kind} | _]),
    do: "#{sev}: #{kind} — #{title || "(no title)"}"

  # Public only for unit testing — do not call from outside `GetAdHealth`.
  # Returns `nil` when `map` cannot be encoded (e.g. an unexpected pid/ref
  # smuggled into a health-score field). Mirrors the safe pattern used by
  # `Chat.Server.format_tool_results/2` — never raises.
  @doc false
  def truncate(nil, _len), do: nil

  def truncate(map, len) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> String.slice(json, 0, len)
      {:error, _} -> nil
    end
  end

  def truncate(other, len), do: other |> to_string() |> String.slice(0, len)
end
