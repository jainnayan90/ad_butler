defmodule AdButler.Chat.Tools.GetFindings do
  @moduledoc """
  Read tool — returns up to N of the user's recent findings, optionally
  filtered by severity and kind.

  Re-scopes via `Analytics.paginate_findings/2` (which scopes through the
  user's ad accounts). Returns ID/kind/severity/title metadata only — no
  body, no evidence — so the LLM follows up with `get_ad_health` (or a
  W10 link) for diagnosis.
  """

  use Jido.Action,
    name: "get_findings",
    description:
      "List the user's recent open findings, optionally filtered by severity and kind.",
    schema: [
      severity_filter: [
        type: {:in, ["low", "medium", "high"]},
        required: false,
        doc: "Severity filter (low/medium/high). Defaults to all."
      ],
      kind_filter: [
        type: :string,
        required: false,
        doc: "Finding kind filter (e.g. dead_spend, creative_fatigue)."
      ],
      limit: [
        type: :pos_integer,
        default: 10,
        doc: "Number of findings to return (max 25)."
      ]
    ]

  alias AdButler.Analytics
  alias AdButler.Chat.Tools.Helpers

  @max_limit 25

  @impl true
  def run(params, context) do
    case Helpers.context_user(context) do
      {:ok, user} ->
        opts =
          [per_page: clamp_limit(Map.get(params, :limit, 10))]
          |> maybe_put(:severity, Map.get(params, :severity_filter))
          |> maybe_put(:kind, Map.get(params, :kind_filter))

        {findings, total} = Analytics.paginate_findings(user, opts)

        {:ok,
         %{
           total_matching: total,
           findings: Enum.map(findings, &summarise/1)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp_limit(_), do: 10

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp summarise(f) do
    %{
      id: f.id,
      kind: f.kind,
      severity: f.severity,
      title: f.title,
      ad_id: f.ad_id,
      inserted_at: f.inserted_at
    }
  end
end
