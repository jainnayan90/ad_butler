defmodule AdButler.Chat.SpikeAgent do
  @moduledoc false

  use Jido.Agent,
    name: "spike_agent",
    description: "W9D0-T1 throwaway agent — confirms Jido 2.2 shape.",
    schema: [
      session_id: [type: :string, default: ""],
      counter: [type: :integer, default: 0]
    ]
end
