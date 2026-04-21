defmodule AdButler.Workers.TokenRefreshWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: {23, :hours}, keys: [:meta_connection_id]]

  require Logger

  @seconds_per_day 86_400
  @refresh_buffer_days 10
  @min_refresh_days 1
  @max_refresh_days 60

  alias AdButler.Accounts
  alias AdButler.ErrorHelpers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meta_connection_id" => id}}) do
    case Accounts.get_meta_connection(id) do
      nil ->
        {:cancel, "connection not found"}

      connection ->
        do_refresh(connection)
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @spec schedule_refresh(%AdButler.Accounts.MetaConnection{}, pos_integer()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_refresh(%AdButler.Accounts.MetaConnection{} = conn, days) do
    %{"meta_connection_id" => conn.id}
    |> new(schedule_in: {days, :days})
    |> Oban.insert()
  end

  defp do_refresh(connection) do
    id = connection.id

    case meta_client().refresh_token(connection.access_token) do
      {:ok, %{"access_token" => token, "expires_in" => expires_in}} ->
        # Meta returns seconds; if milliseconds, div gives 0 → clamped to 1 day
        expiry = DateTime.add(DateTime.utc_now(), expires_in, :second)

        case Accounts.update_meta_connection(connection, %{
               access_token: token,
               token_expires_at: expiry
             }) do
          {:ok, _} ->
            schedule_result = schedule_next_refresh(connection, expires_in)
            Logger.info("Token refresh success", meta_connection_id: id)

            case schedule_result do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.error("Token re-schedule failed",
                  meta_connection_id: id,
                  reason: reason
                )

                :ok
            end

          {:error, reason} ->
            Logger.error("Token refresh update failed",
              meta_connection_id: id,
              reason: reason
            )

            {:error, :update_failed}
        end

      {:error, reason} when reason in [:unauthorized, :token_revoked] ->
        _ =
          case Accounts.update_meta_connection(connection, %{status: "revoked"}) do
            {:ok, _} ->
              :ok

            {:error, err} ->
              Logger.warning("Failed to mark connection revoked",
                meta_connection_id: id,
                reason: err
              )
          end

        Logger.warning("Token revoked, cancelling refresh",
          meta_connection_id: id,
          reason: reason
        )

        {:cancel, Atom.to_string(reason)}

      {:error, :rate_limit_exceeded} ->
        Logger.warning("Rate limit hit, snoozing refresh", meta_connection_id: id)
        # Snooze consumes one attempt (max_attempts: 5). Acceptable because the
        # sweep worker recovers any missed refresh within 6 h via its own schedule.
        {:snooze, 3600}

      {:error, reason} ->
        Logger.error("Token refresh failed",
          meta_connection_id: id,
          reason: ErrorHelpers.safe_reason(reason)
        )

        {:error, reason}
    end
  end

  defp schedule_next_refresh(connection, expires_in_seconds) do
    days =
      expires_in_seconds
      |> div(@seconds_per_day)
      |> Kernel.-(@refresh_buffer_days)
      |> max(@min_refresh_days)
      |> min(@max_refresh_days)

    case schedule_refresh(connection, days) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule next refresh",
          meta_connection_id: connection.id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp meta_client do
    Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)
  end
end
