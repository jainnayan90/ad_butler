defmodule AdButlerWeb.ChatLive.Components do
  @moduledoc """
  Function components for `ChatLive.Show`: message bubbles, the
  in-flight streaming bubble, chart blocks, and tool-call accordions.

  All styling is plain Tailwind utility classes — DaisyUI component
  classes are banned per CLAUDE.md.

  ## Charts

  Inline charts render from the `points` field of a
  `get_insights_series` tool result. We always go through
  `AdButlerWeb.Charts.line_plot/2`, which returns
  `{:safe, iolist}` — Phoenix renders this safely without `raw/1`.
  Per Iron Law #12 (no `raw/1` with variable), we never persist a
  raw SVG string and call `raw/1` on it later.
  """

  use Phoenix.Component

  alias AdButlerWeb.Charts

  @doc """
  Renders a single message based on `role`. User and assistant
  bubbles align right and left respectively; tool messages collapse
  via a native `<details>` block; system errors render as an amber
  pill.
  """
  attr :message, :map, required: true

  def message_bubble(%{message: %{role: "user"}} = assigns) do
    ~H"""
    <div class="flex justify-end">
      <div class="bg-blue-600 text-white rounded-2xl px-4 py-2 max-w-2xl whitespace-pre-wrap">
        {@message.content}
      </div>
    </div>
    """
  end

  def message_bubble(%{message: %{role: "assistant"}} = assigns) do
    ~H"""
    <div class="flex justify-start">
      <div class="bg-gray-100 text-gray-900 rounded-2xl px-4 py-2 max-w-2xl whitespace-pre-wrap">
        <div :if={@message.content}>{@message.content}</div>
        <.tool_results_block :if={has_tool_results?(@message)} results={@message.tool_results} />
      </div>
    </div>
    """
  end

  def message_bubble(%{message: %{role: "tool"}} = assigns) do
    ~H"""
    <div class="flex justify-start">
      <div class="bg-gray-50 border border-gray-200 rounded-2xl px-4 py-2 max-w-2xl">
        <.tool_results_block :if={has_tool_results?(@message)} results={@message.tool_results} />
        <div :if={!has_tool_results?(@message)} class="text-xs text-gray-500">
          (tool result)
        </div>
      </div>
    </div>
    """
  end

  def message_bubble(%{message: %{role: "system_error"}} = assigns) do
    ~H"""
    <div class="bg-amber-50 text-amber-900 border border-amber-200 rounded-md px-4 py-2 text-sm">
      <span class="font-medium">Error:</span> {@message.content}
    </div>
    """
  end

  def message_bubble(assigns) do
    ~H"""
    <div class="text-xs text-gray-400 italic">unknown role: {@message.role}</div>
    """
  end

  @doc """
  Renders the in-flight assistant bubble that accumulates streaming
  chunks. Includes a blinking cursor span and an optional transient
  tool-indicator label.
  """
  attr :chunk, :string, required: true
  attr :tool, :string, default: nil

  def streaming_bubble(assigns) do
    ~H"""
    <div class="flex justify-start">
      <div class="bg-gray-100 text-gray-900 rounded-2xl px-4 py-2 max-w-2xl whitespace-pre-wrap">
        <div :if={@tool} class="text-xs text-gray-500 mb-1">Calling {@tool}…</div>
        <span>{@chunk}</span><span class="animate-pulse">▋</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a chart from a list of `%{date, value}` points. The Contex
  output is wrapped in `{:safe, iolist}` by `Charts.line_plot/2` —
  Phoenix renders it without escaping, no `raw/1` needed.
  """
  attr :points, :list, required: true
  attr :title, :string, default: nil
  attr :metric, :string, default: nil

  def chart_block(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-lg p-4 my-2">
      <div :if={@title} class="text-xs font-medium text-gray-700 mb-2">{@title}</div>
      {Charts.line_plot(@points, title: @title, units: @metric)}
    </div>
    """
  end

  @doc """
  Renders a collapsible block for a non-chart tool call result.
  Native `<details>` — no JS, no DaisyUI.
  """
  attr :name, :string, required: true
  attr :args, :any, default: nil
  attr :result, :any, default: nil

  def tool_call(assigns) do
    ~H"""
    <details class="my-2 bg-gray-50 border border-gray-200 rounded p-2 text-xs text-gray-700">
      <summary class="cursor-pointer font-medium">Tool: {@name}</summary>
      <div :if={@args} class="mt-2">
        <span class="font-medium">args:</span>
        <pre class="whitespace-pre-wrap break-all">{truncate(inspect(@args, pretty: true), 500)}</pre>
      </div>
      <div :if={@result} class="mt-2">
        <span class="font-medium">result:</span>
        <pre class="whitespace-pre-wrap break-all">{truncate(inspect(@result, pretty: true), 500)}</pre>
      </div>
    </details>
    """
  end

  # --------------------------------------------------------------------------
  # Internal: walk tool_results and pick the right component for each entry
  # --------------------------------------------------------------------------

  attr :results, :list, required: true

  defp tool_results_block(assigns) do
    ~H"""
    <div class="mt-2 space-y-1">
      <div :for={entry <- @results}>
        <.chart_block
          :if={chart_points(entry)}
          points={chart_points(entry)}
          title={chart_title(entry)}
          metric={chart_metric(entry)}
        />
        <.tool_call
          :if={is_nil(chart_points(entry))}
          name={tool_name(entry)}
          args={Map.get(entry, "args")}
          result={Map.get(entry, "result")}
        />
      </div>
    </div>
    """
  end

  defp has_tool_results?(%{tool_results: results}) when is_list(results) and results != [],
    do: true

  defp has_tool_results?(_), do: false

  defp chart_points(%{
         "name" => "get_insights_series",
         "ok" => true,
         "result" => %{"points" => points}
       })
       when is_list(points),
       do: points

  defp chart_points(_), do: nil

  defp chart_title(%{"result" => %{"metric" => metric, "window" => window}})
       when is_binary(metric),
       do: "#{metric} — #{window}"

  defp chart_title(%{"result" => %{"metric" => metric}}) when is_binary(metric), do: metric
  defp chart_title(_), do: "series"

  defp chart_metric(%{"result" => %{"metric" => metric}}) when is_binary(metric), do: metric
  defp chart_metric(_), do: nil

  defp tool_name(%{"name" => n}) when is_binary(n), do: n
  defp tool_name(_), do: "tool"

  defp truncate(str, max) when is_binary(str) do
    if byte_size(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end
end
