defmodule AdButler.Messaging.PublisherPool do
  @moduledoc """
  Process pool for AMQP message publishing.

  Maintains N `Publisher` workers (configured via `pool_size` in the `:rabbitmq`
  app env, default 5). Workers are supervised under a one-for-one strategy and
  registered in a private `Registry` by index. Publish calls are dispatched via
  lock-free round-robin using `:atomics`.

  Implements `PublisherBehaviour` so it can be used as a drop-in replacement for
  `Publisher` in tests or other injection points.

  Gating behind `env != :test` in `Application` keeps test startup unchanged.
  """
  @behaviour AdButler.Messaging.PublisherBehaviour

  use Supervisor

  alias AdButler.Messaging.Publisher

  @registry AdButler.Messaging.PublisherPool.Registry
  @default_exchange "ad_butler.sync.fanout"

  @doc "Starts the PublisherPool supervisor."
  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Publishes `payload` to the default sync fanout exchange via a round-robin selected pool worker. Returns `{:error, :not_connected}` if the selected worker has no AMQP channel."
  @impl AdButler.Messaging.PublisherBehaviour
  @spec publish(binary()) :: :ok | {:error, term()}
  def publish(payload), do: publish(payload, @default_exchange)

  @doc "Publishes `payload` to `exchange` via a round-robin selected pool worker. Returns `{:error, :not_connected}` if the selected worker has no AMQP channel."
  @impl AdButler.Messaging.PublisherBehaviour
  @spec publish(binary(), String.t()) :: :ok | {:error, term()}
  def publish(payload, exchange) when is_binary(exchange) do
    pool_size = :persistent_term.get({__MODULE__, :pool_size})
    counter = :persistent_term.get({__MODULE__, :counter})
    index = rem(:atomics.add_get(counter, 1, 1), pool_size)

    case Registry.lookup(@registry, index) do
      [{pid, _}] -> GenServer.call(pid, {:publish, payload, exchange})
      [] -> {:error, :not_connected}
    end
  end

  @doc "Blocks until all pool workers have an open AMQP channel or `timeout` ms elapses."
  @spec await_connected(timeout()) :: :ok | {:error, :timeout}
  def await_connected(timeout \\ 10_000) do
    pool_size = :persistent_term.get({__MODULE__, :pool_size})
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(0..(pool_size - 1), :ok, fn index, :ok ->
      [{pid, _}] = Registry.lookup(@registry, index)
      remaining = max(deadline - System.monotonic_time(:millisecond), 50)

      case Publisher.await_connected_for(pid, remaining) do
        :ok -> {:cont, :ok}
        {:error, :timeout} -> {:halt, {:error, :timeout}}
      end
    end)
  end

  @impl Supervisor
  def init(_opts) do
    pool_size = Application.get_env(:ad_butler, :rabbitmq, [])[:pool_size] || 5
    # Seed at pool_size - 1 so the first add_get returns pool_size, and
    # rem(pool_size, pool_size) == 0, ensuring worker 0 is the first selected.
    counter = :atomics.new(1, signed: false)
    :atomics.put(counter, 1, pool_size - 1)
    :persistent_term.put({__MODULE__, :counter}, counter)
    :persistent_term.put({__MODULE__, :pool_size}, pool_size)

    workers =
      Enum.map(0..(pool_size - 1), fn i ->
        Supervisor.child_spec(
          {Publisher, [name: {:via, Registry, {@registry, i}}]},
          id: {Publisher, i}
        )
      end)

    children = [{Registry, keys: :unique, name: @registry}] ++ workers

    Supervisor.init(children, strategy: :one_for_one)
  end
end
