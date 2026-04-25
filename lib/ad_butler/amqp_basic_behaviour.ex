defmodule AdButler.AMQPBasicBehaviour do
  @moduledoc """
  Behaviour for AMQP basic operations (`get`, `publish`, `ack`, `nack`).

  Implemented by `AMQP.Basic` in production. Inject a mock via
  `Application.put_env(:ad_butler, :amqp_basic, MyMock)` in tests to avoid
  requiring a live RabbitMQ connection.
  """

  @callback get(channel :: term(), queue :: String.t(), opts :: keyword()) ::
              {:ok, String.t(), map()} | {:empty, map()}

  @callback publish(
              channel :: term(),
              exchange :: String.t(),
              routing_key :: String.t(),
              payload :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @callback ack(channel :: term(), delivery_tag :: term()) :: :ok | {:error, term()}

  @callback nack(channel :: term(), delivery_tag :: term(), opts :: keyword()) ::
              :ok | {:error, term()}
end
