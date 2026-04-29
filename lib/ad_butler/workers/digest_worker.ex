defmodule AdButler.Workers.DigestWorker do
  @moduledoc "Delivers a digest email for one user."

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: {25, :hours}, fields: [:args, :queue, :worker], keys: [:user_id, :period]]

  alias AdButler.{Accounts, Notifications}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "period" => period}})
      when period in ["daily", "weekly"] do
    case Accounts.get_user(user_id) do
      nil ->
        {:cancel, "user not found"}

      user ->
        case Notifications.deliver_digest(user, period) do
          :ok -> :ok
          {:skip, :no_findings} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def perform(%Oban.Job{args: args}),
    do: {:cancel, "invalid period: #{inspect(Map.get(args, "period"))}"}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)
end
