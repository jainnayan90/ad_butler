defmodule AdButler.Notifications do
  @moduledoc "Email digest and notification delivery."

  require Logger

  alias AdButler.Accounts.User
  alias AdButler.{Analytics, Mailer}
  alias AdButler.Notifications.DigestMailer

  @doc """
  Delivers a digest email to `user` for the given period.

  Returns `:ok` on success, or `{:skip, :no_findings}` when there are no
  high- or medium-severity findings in the period window.
  """
  @spec deliver_digest(User.t(), String.t()) :: :ok | {:skip, :no_findings} | {:error, term()}
  def deliver_digest(%User{} = user, period) when period in ["daily", "weekly"] do
    hours = if period == "daily", do: 24, else: 168
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    user
    |> Analytics.list_high_medium_findings_since(since)
    |> do_deliver(user, period)
  end

  defp do_deliver({[], _total}, _user, _period), do: {:skip, :no_findings}

  defp do_deliver({findings, total}, user, period) do
    email = DigestMailer.build(user, findings, period, total)

    case Mailer.deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("digest delivery failed",
          user_id: user.id,
          period: period,
          reason: inspect(reason)
        )

        {:error, :delivery_failed}
    end
  end
end
