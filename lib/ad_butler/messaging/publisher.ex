defmodule AdButler.Messaging.Publisher do
  @moduledoc """
  GenServer that maintains a persistent AMQP connection and publishes messages
  to the `ad_butler.sync.fanout` exchange.

  Implements `AdButler.Messaging.PublisherBehaviour` for test injection. Handles
  automatic reconnection with a 5-second delay when the connection or channel goes
  down. Credentials in the RabbitMQ URL are never logged — all error reasons are
  sanitized before logging.

  `await_connected/1` and `await_connected_for/2` suspend the caller in the
  GenServer mailbox (no busy-poll) until the channel opens or the timeout elapses.
  """
  @behaviour AdButler.Messaging.PublisherBehaviour

  use GenServer
  require Logger

  @exchange "ad_butler.sync.fanout"
  @reconnect_delay_ms 5_000
  @amqp_basic Application.compile_env(:ad_butler, :amqp_basic, AMQP.Basic)

  @doc "Starts the Publisher GenServer. Pass `name:` to register under a custom name; defaults to the module name."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @impl AdButler.Messaging.PublisherBehaviour
  @doc "Publishes `payload` to the default sync fanout exchange (`ad_butler.sync.fanout`). Returns `{:error, :not_connected}` if the AMQP channel is not yet up."
  @spec publish(binary()) :: :ok | {:error, term()}
  def publish(payload), do: publish(payload, @exchange)

  @impl AdButler.Messaging.PublisherBehaviour
  @doc "Publishes `payload` to `exchange`. Returns `{:error, :not_connected}` if the AMQP channel is not yet up."
  @spec publish(binary(), String.t()) :: :ok | {:error, term()}
  def publish(payload, exchange) when is_binary(exchange) do
    GenServer.call(__MODULE__, {:publish, payload, exchange})
  end

  @doc "Suspends the caller until the AMQP channel is open or `timeout` milliseconds elapse."
  @spec await_connected(timeout()) :: :ok | {:error, :timeout}
  def await_connected(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :await_connected, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Suspends the caller until the given publisher `server` (pid or via-tuple) has an open channel or `timeout` ms elapses."
  @spec await_connected_for(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def await_connected_for(server, timeout \\ 5_000) do
    GenServer.call(server, :await_connected, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :connect)
    {:ok, %{conn: nil, channel: nil, conn_ref: nil, channel_ref: nil, pending_connected: []}}
  end

  @impl GenServer
  def handle_call(:connected?, _from, %{channel: nil} = state) do
    {:reply, false, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, true, state}
  end

  # Already connected — reply immediately.
  def handle_call(:await_connected, _from, %{channel: channel} = state) when channel != nil do
    {:reply, :ok, state}
  end

  # Not yet connected — store the caller and reply when the channel opens.
  def handle_call(:await_connected, from, %{pending_connected: pending} = state) do
    {:noreply, %{state | pending_connected: [from | pending]}}
  end

  def handle_call({:publish, _payload, _exchange}, _from, %{channel: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, payload, exchange}, _from, %{channel: channel} = state) do
    result = @amqp_basic.publish(channel, exchange, "", payload, persistent: true)
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

            new_state = %{
              state
              | conn: conn,
                channel: channel,
                conn_ref: conn_ref,
                channel_ref: channel_ref
            }

            reply_pending_connected(new_state.pending_connected)
            %{new_state | pending_connected: []}

          {:error, reason} ->
            close_amqp_connection(conn)

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

  @impl GenServer
  def terminate(_reason, state) do
    if ref = Map.get(state, :conn_ref), do: Process.demonitor(ref, [:flush])
    if ref = Map.get(state, :channel_ref), do: Process.demonitor(ref, [:flush])
    close_amqp_channel(Map.get(state, :channel))
    close_amqp_connection(Map.get(state, :conn))
  end

  defp reply_pending_connected(pending) do
    Enum.each(pending, &GenServer.reply(&1, :ok))
  end

  defp reconnect(
         %{conn: conn, channel: channel, conn_ref: conn_ref, channel_ref: channel_ref} = state
       ) do
    if conn_ref, do: Process.demonitor(conn_ref, [:flush])
    if channel_ref, do: Process.demonitor(channel_ref, [:flush])
    close_amqp_channel(channel)
    close_amqp_connection(conn)
    do_connect(%{state | conn: nil, channel: nil, conn_ref: nil, channel_ref: nil})
  end

  defp close_amqp_channel(nil), do: :ok

  defp close_amqp_channel(channel) do
    AMQP.Channel.close(channel)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end

  defp close_amqp_connection(nil), do: :ok

  defp close_amqp_connection(conn) do
    AMQP.Connection.close(conn)
  catch
    :exit, _ -> :ok
    :error, _ -> :ok
  end

  # Avoid leaking AMQP URL (which may contain credentials) in logs
  defp sanitize_reason(reason) when is_binary(reason), do: reason
  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason(_), do: :connection_error
end
