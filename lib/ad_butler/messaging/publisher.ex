defmodule AdButler.Messaging.Publisher do
  @moduledoc false
  @behaviour AdButler.Messaging.PublisherBehaviour

  use GenServer
  require Logger

  @exchange "ad_butler.sync.fanout"
  @reconnect_delay_ms 5_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl AdButler.Messaging.PublisherBehaviour
  @spec publish(binary()) :: :ok | {:error, term()}
  def publish(payload) do
    GenServer.call(__MODULE__, {:publish, payload})
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :connect)
    {:ok, %{conn: nil, channel: nil, conn_ref: nil, channel_ref: nil}}
  end

  @impl GenServer
  def handle_call({:publish, _payload}, _from, %{channel: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, payload}, _from, %{channel: channel} = state) do
    result = AMQP.Basic.publish(channel, @exchange, "", payload, persistent: true)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    {:noreply, do_connect(state)}
  end

  def handle_info({:basic_cancel, _}, state) do
    Logger.warning("AMQP consumer cancelled — reconnecting")
    {:noreply, reconnect(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    Logger.warning("AMQP connection down", reason: inspect(reason))
    {:noreply, reconnect(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{channel_ref: ref} = state) do
    Logger.warning("AMQP channel down", reason: inspect(reason))
    {:noreply, reconnect(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_connect(state) do
    url = Application.fetch_env!(:ad_butler, :rabbitmq)[:url]

    case AMQP.Connection.open(url) do
      {:ok, conn} ->
        case AMQP.Channel.open(conn) do
          {:ok, channel} ->
            conn_ref = Process.monitor(conn.pid)
            channel_ref = Process.monitor(channel.pid)
            %{state | conn: conn, channel: channel, conn_ref: conn_ref, channel_ref: channel_ref}

          {:error, reason} ->
            try do
              AMQP.Connection.close(conn)
            catch
              :exit, _ -> :ok
              :error, _ -> :ok
            end

            Logger.warning("AMQP channel open failed, retrying",
              reason: sanitize_reason(reason),
              delay_ms: @reconnect_delay_ms
            )

            Process.send_after(self(), :connect, @reconnect_delay_ms)
            state
        end

      {:error, reason} ->
        Logger.warning("AMQP connection failed, retrying",
          reason: sanitize_reason(reason),
          delay_ms: @reconnect_delay_ms
        )

        Process.send_after(self(), :connect, @reconnect_delay_ms)
        state
    end
  end

  defp reconnect(%{conn_ref: conn_ref, channel_ref: channel_ref} = state) do
    if conn_ref, do: Process.demonitor(conn_ref, [:flush])
    if channel_ref, do: Process.demonitor(channel_ref, [:flush])
    do_connect(%{state | conn: nil, channel: nil, conn_ref: nil, channel_ref: nil})
  end

  # Avoid leaking AMQP URL (which may contain credentials) in logs
  defp sanitize_reason(reason) when is_binary(reason), do: reason
  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason(_), do: :connection_error
end
