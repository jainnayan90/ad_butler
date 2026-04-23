defmodule AdButler.Messaging.PublisherBehaviour do
  @moduledoc """
  Behaviour for the AMQP message publisher.

  Implemented by `AdButler.Messaging.Publisher`. Inject a mock via
  `Application.put_env(:ad_butler, :messaging_publisher, MyMock)` in tests.
  """
  @callback publish(binary()) :: :ok | {:error, term()}
end
