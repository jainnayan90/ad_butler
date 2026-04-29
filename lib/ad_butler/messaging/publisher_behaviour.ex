defmodule AdButler.Messaging.PublisherBehaviour do
  @moduledoc """
  Behaviour for the AMQP message publisher.

  Implemented by `AdButler.Messaging.Publisher`. Inject a mock via
  `Application.put_env(:ad_butler, :messaging_publisher, MyMock)` in tests.

  `publish/1` defaults to the sync fanout exchange (`ad_butler.sync.fanout`).
  Use `publish/2` to target a different exchange (e.g. `ad_butler.insights.fanout`).
  """
  @callback publish(binary()) :: :ok | {:error, term()}
  @callback publish(binary(), String.t()) :: :ok | {:error, term()}
end
