defmodule AdButler.AMQPBasicBehaviour do
  @moduledoc false

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
