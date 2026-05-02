# W9D0 spike — runs T1, T2, T3 and writes findings to priv/spike/findings.md.
#
# Run with: source .env.local && mix run --no-start priv/spike/run.exs
# (--no-start skips AdButler.Application boot so we don't need RabbitMQ)

Code.require_file("priv/spike/spike_agent.ex")

# Boot just the dep apps we need (Jido, ReqLLM, Finch, Telemetry).
# We avoid AdButler.Application because it requires RabbitMQ in dev.
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:req_llm)
Application.ensure_all_started(:jido)
Application.ensure_all_started(:jido_ai)

# Jido 2.2 expects the host to start a Jido instance (which owns Jido.Registry,
# the agent supervisor, etc.). The default instance name is `Jido`.
{:ok, _jido_pid} = Jido.start_link(name: Jido)

defmodule AdButler.SpikeRunner do
  @moduledoc false
  require Logger

  @findings_path "priv/spike/findings.md"

  def run do
    File.write!(@findings_path, "# W9D0 spike findings\n\nGenerated: #{DateTime.utc_now()}\n\n")
    log("---")

    section("T1 — Jido.Agent shape")
    t1()

    section("T2 — [:req_llm, :token_usage] event shape")
    t2()

    section("T3 — Streaming chunk delivery")
    t3()

    log("\n---\nSpike complete. See #{@findings_path}.")
  end

  # -------------------------------------------------------------------------
  # T1: confirm Jido.Agent + AgentServer start signature, state shape
  # -------------------------------------------------------------------------
  defp t1 do
    log("**Module:** `AdButler.Chat.SpikeAgent`")
    log("Defined with `use Jido.Agent, name: \"spike_agent\", schema: [session_id, counter]`.")

    # 1a — pure Agent.new
    agent = AdButler.Chat.SpikeAgent.new()
    log("\n`SpikeAgent.new/0` returns: ```\n#{inspect(agent, pretty: true, limit: 50)}\n```")
    log("**Agent struct keys:** #{inspect(Map.keys(agent))}")

    # 1b — start under AgentServer
    case Jido.AgentServer.start_link(agent: AdButler.Chat.SpikeAgent) do
      {:ok, pid} ->
        log("\n`Jido.AgentServer.start_link(agent: SpikeAgent)` → `{:ok, #{inspect(pid)}}`.")
        sys_state = :sys.get_state(pid)
        log("`:sys.get_state/1` keys: #{inspect(Map.keys(sys_state))}")
        log("State.agent keys: #{inspect(Map.keys(sys_state.agent))}")

        # try with initial_state
        GenServer.stop(pid)

        {:ok, pid2} =
          Jido.AgentServer.start_link(
            agent: AdButler.Chat.SpikeAgent,
            initial_state: %{session_id: "abc-123", counter: 7}
          )

        agent2 = :sys.get_state(pid2).agent

        log(
          "\nWith `initial_state:` map → `agent.state.session_id == #{inspect(agent2.state.session_id)}`, `counter == #{inspect(agent2.state.counter)}`."
        )

        GenServer.stop(pid2)

      other ->
        log("`Jido.AgentServer.start_link/1` returned: `#{inspect(other)}`.")
    end
  end

  # -------------------------------------------------------------------------
  # T2: capture [:req_llm, :token_usage] event shape via real embed call
  # -------------------------------------------------------------------------
  defp t2 do
    parent = self()
    handler_id = "spike-t2-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:req_llm, :token_usage],
        [:req_llm, :request, :start],
        [:req_llm, :request, :stop],
        [:req_llm, :request, :exception]
      ],
      fn event, measurements, metadata, _ ->
        send(parent, {:tel, event, measurements, metadata})
      end,
      nil
    )

    log(
      "Calling `ReqLLM.embed(\"openai:text-embedding-3-small\", [\"hello world\"])` with attached telemetry…"
    )

    case ReqLLM.embed("openai:text-embedding-3-small", ["hello world"]) do
      {:ok, vectors} when is_list(vectors) and length(vectors) > 0 ->
        log("`embed/2` returned `{:ok, [#{length(vectors)} vector(s)]}`.")

      {:ok, other} ->
        log("`embed/2` returned `{:ok, ...}` of unexpected shape: `#{inspect(other, limit: 5)}`")

      {:error, reason} ->
        log("`embed/2` failed: `#{inspect(reason, limit: 20)}`")
    end

    events = drain_telemetry([])
    log("\nCaptured #{length(events)} telemetry event(s):")

    for {event, measurements, metadata} <- events do
      log("\n#### `#{inspect(event)}`")
      log("- **measurements keys:** #{inspect(Map.keys(measurements))}")
      log("- **measurements:** ```\n#{inspect(measurements, pretty: true, limit: 50)}\n```")
      log("- **metadata keys:** #{inspect(Map.keys(metadata))}")

      summary =
        metadata
        |> Map.take([:provider, :model, :operation, :request_id, :usage, :http_status])
        |> Map.update(:usage, nil, fn u -> if u, do: Map.keys(u), else: nil end)

      log("- **metadata summary:** `#{inspect(summary, limit: 30)}`")
    end

    :telemetry.detach(handler_id)
  end

  defp drain_telemetry(acc) do
    receive do
      {:tel, e, m, md} -> drain_telemetry([{e, m, md} | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  # -------------------------------------------------------------------------
  # T3: observe streaming chunk delivery shape
  # -------------------------------------------------------------------------
  defp t3 do
    log("Calling `Jido.AI.stream_text(\"count to 3\", model: \"anthropic:claude-haiku-4-5\")`…")

    result =
      Jido.AI.stream_text("count to 3, one number per line",
        model: "anthropic:claude-haiku-4-5",
        max_tokens: 30
      )

    case result do
      {:ok, %ReqLLM.StreamResponse{} = stream_response} ->
        log("Returns `%ReqLLM.StreamResponse{}`. Keys: #{inspect(Map.keys(stream_response))}")

        # The stream is single-pass — calling Enum.take and then iterating again
        # crashes (GenServer for the lazy stream is dead). Capture chunks AND text
        # in one fold.
        chunks = Enum.to_list(stream_response.stream)

        log(
          "\nTotal chunks: #{length(chunks)}. **The stream is consumed once** — re-iterating crashes the lazy GenServer (recorded as a footgun)."
        )

        log("\nFirst 20 chunks:")

        chunks
        |> Enum.take(20)
        |> Enum.with_index(1)
        |> Enum.each(fn {chunk, idx} ->
          log("- `[#{idx}]` `#{inspect(chunk, limit: 5, printable_limit: 80)}`")
        end)

        # Categorise chunk types
        types = chunks |> Enum.frequencies_by(& &1.type)
        log("\n**Chunk type frequencies:** `#{inspect(types)}`")

        text = chunks |> Enum.map(&extract_text/1) |> Enum.join()
        log("\n**Concatenated content text:** ```\n#{String.slice(text, 0, 200)}\n```")

        # Show the keys of any meta chunk that carries usage
        chunks
        |> Enum.filter(&match?(%{type: :meta, metadata: %{usage: _}}, &1))
        |> Enum.take(1)
        |> Enum.each(fn meta_chunk ->
          log(
            "\n**Sample :meta usage chunk metadata keys:** `#{inspect(Map.keys(meta_chunk.metadata))}`"
          )

          log(
            "**Sample :meta usage chunk metadata.usage:** `#{inspect(meta_chunk.metadata.usage, limit: 30)}`"
          )
        end)

      {:ok, other} ->
        log("Returned `{:ok, ...}` of unexpected shape: `#{inspect(other, limit: 5)}`")

      {:error, error} ->
        log("`stream_text` failed: `#{inspect(error, limit: 20)}`")
    end
  end

  defp extract_text(%{type: :content, text: text}) when is_binary(text), do: text

  defp extract_text(%ReqLLM.StreamChunk{type: :content, text: text}) when is_binary(text),
    do: text

  defp extract_text(_), do: ""

  # -------------------------------------------------------------------------
  # Output helpers — tee to stdout AND findings file
  # -------------------------------------------------------------------------
  defp section(title) do
    log("\n## #{title}\n")
  end

  defp log(line) do
    IO.puts(line)
    File.write!(@findings_path, line <> "\n", [:append])
  end
end

AdButler.SpikeRunner.run()
