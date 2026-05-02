defmodule AdButler.Chat.Tools.Helpers do
  @moduledoc """
  Shared helpers for the read-only chat tools (`get_ad_health`,
  `get_findings`, `get_insights_series`, `compare_creatives`,
  `simulate_budget_change`).

  Three concerns showed up in every tool before W12:

    * `context_user/1` — pulls the calling user out of the agent's
      `:session_context` map and re-fetches the `Accounts.User` for
      tenant scoping. The `:missing_session_context` error keeps
      tools that never receive a session_context (a misuse) from
      silently leaking data.
    * `decimal_to_float/1` — `Decimal` values from health scores must
      be coerced before they hit JSON.
    * `maybe_payload_field/2` — nil-safe `Map.get/2` for the optional
      health row that may not exist for a freshly-ingested ad.
  """

  alias AdButler.Accounts
  alias AdButler.Accounts.User

  @doc """
  Resolves the calling user from a `Jido.Action` execution context.
  Returns `{:ok, %User{}}` for an authorised session, `{:error,
  :missing_session_context}` if the caller forgot to wire it,
  `{:error, :not_found}` if the user_id no longer matches a row.
  """
  @spec context_user(map()) :: {:ok, User.t()} | {:error, :missing_session_context | :not_found}
  def context_user(%{session_context: %{user_id: user_id}}) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %User{} = user -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  def context_user(_), do: {:error, :missing_session_context}

  @doc """
  Converts a `Decimal`, number, or `nil` to a float (or `nil`). Used to
  flatten health scores and numeric metrics before serialising tool
  payloads with `Jason.encode!/1`.
  """
  @spec decimal_to_float(any()) :: nil | float()
  def decimal_to_float(nil), do: nil
  def decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  def decimal_to_float(n) when is_number(n), do: n / 1
  def decimal_to_float(_), do: nil

  @doc """
  Nil-safe `Map.get/2`: returns `nil` if the payload is `nil`, otherwise
  reads `key`. Saves an `if`/`case` at every call site that pulls a
  field off an optionally-present struct.
  """
  @spec maybe_payload_field(nil | map() | struct(), atom()) :: any()
  def maybe_payload_field(nil, _key), do: nil
  def maybe_payload_field(payload, key), do: Map.get(payload, key)
end
