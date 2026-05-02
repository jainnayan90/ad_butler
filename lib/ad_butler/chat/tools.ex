defmodule AdButler.Chat.Tools do
  @moduledoc """
  Single source of truth for the chat agent's tool set.

  Day 3 + Day 4 land the 5 read tools. Day 5 closes with the system
  prompt + e2e wiring. Week 11 adds write tools (`PauseAd`, `UnpauseAd`)
  + the confirmation flow — until then, `write_tools/0` returns `[]`.

  All tools call back into context modules (`Ads`, `Analytics`,
  `AdButler.Chat`) — never `Repo` directly. The
  `mix check.tools_no_repo` alias enforces this in CI.
  """

  alias AdButler.Chat.Tools.{
    CompareCreatives,
    GetAdHealth,
    GetFindings,
    GetInsightsSeries,
    SimulateBudgetChange
  }

  @doc "Read-only tools available to the agent. Same shape on every turn."
  @spec read_tools() :: [module()]
  def read_tools do
    [
      GetAdHealth,
      GetFindings,
      GetInsightsSeries,
      CompareCreatives,
      SimulateBudgetChange
    ]
  end

  @doc "Write tools — `[]` until Week 11."
  @spec write_tools() :: [module()]
  def write_tools, do: []

  @doc "Read + write tools concatenated. Used by `Chat.Server` per turn."
  @spec all_tools() :: [module()]
  def all_tools, do: read_tools() ++ write_tools()
end
