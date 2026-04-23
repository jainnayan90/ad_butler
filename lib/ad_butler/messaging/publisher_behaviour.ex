defmodule AdButler.Messaging.PublisherBehaviour do
  @moduledoc false
  @callback publish(binary()) :: :ok | {:error, term()}
end
