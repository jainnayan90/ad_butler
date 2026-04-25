defmodule AdButler.LLM do
  @moduledoc """
  Context for LLM usage tracking.

  Provides read access to the `llm_usage` table. Rows are written exclusively
  via `AdButler.LLM.UsageHandler` in response to telemetry events — this context
  does not expose insert functions.

  All queries are scoped to the requesting user so one user's usage data is never
  accessible to another.
  """

  import Ecto.Query

  alias AdButler.Accounts.User
  alias AdButler.LLM.Usage
  alias AdButler.Repo

  @doc """
  Returns all `llm_usage` rows for `user`, ordered by most-recent first.

  ## Options

  - `:limit` — maximum number of rows to return (default: 100)
  - `:purpose` — filter by purpose string (e.g. `"chat_response"`)
  - `:provider` — filter by provider string (e.g. `"anthropic"`)
  - `:status` — filter by status string (e.g. `"success"`)
  """
  def list_usage_for_user(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    purpose = Keyword.get(opts, :purpose)
    provider = Keyword.get(opts, :provider)
    status = Keyword.get(opts, :status)

    from(u in Usage, where: u.user_id == ^user_id, order_by: [desc: u.inserted_at], limit: ^limit)
    |> maybe_filter(:purpose, purpose)
    |> maybe_filter(:provider, provider)
    |> maybe_filter(:status, status)
    |> Repo.all()
  end

  @doc """
  Returns the total cost in cents across all LLM calls for `user`.

  Returns `%{input_cents: integer, output_cents: integer, total_cents: integer}`.
  """
  def total_cost_for_user(%User{id: user_id}) do
    from(u in Usage,
      where: u.user_id == ^user_id,
      select: %{
        input_cents: coalesce(sum(u.cost_cents_input), 0),
        output_cents: coalesce(sum(u.cost_cents_output), 0),
        total_cents: coalesce(sum(u.cost_cents_total), 0)
      }
    )
    |> Repo.one()
  end

  @doc """
  Returns a single `llm_usage` row by `id`, scoped to `user`.

  Raises `Ecto.NoResultsError` if the record does not exist or belongs to a different user.
  """
  def get_usage!(%User{id: user_id}, id) do
    Repo.get_by!(Usage, id: id, user_id: user_id)
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [u], field(u, ^field) == ^value)
end
