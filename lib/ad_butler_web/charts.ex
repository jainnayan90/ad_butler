defmodule AdButlerWeb.Charts do
  @moduledoc """
  Pure-function wrapper around Contex for chat-inline charts.

  Each function returns `{:safe, iolist}` — Phoenix renders the iolist
  directly without escaping. Per Iron Law #12 we never serialise the
  iolist to a binary and pass it through `Phoenix.HTML.raw/1` later;
  the safe-tuple flows from Contex straight into the component output.
  """

  alias Contex.{Dataset, LinePlot, Plot}

  @default_width 560
  @default_height 220

  @doc """
  Renders a single-series line plot from a list of `%{date, value}` (or
  `%{"date" => _, "value" => _}`) maps. Returns `{:safe, iolist}`.

  Options:

    * `:title` — rendered as the plot title above the axes
    * `:units` — rendered as the y-axis label
    * `:width` / `:height` — defaults `560` / `220`

  Empty or invalid input returns an empty `{:safe, ""}` so the caller
  can render the wrapping card without a special-case branch.
  """
  @spec line_plot([map()], keyword()) :: Phoenix.HTML.safe()
  def line_plot(points, opts \\ [])

  def line_plot([], _opts), do: {:safe, ""}

  def line_plot(points, opts) when is_list(points) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    title = Keyword.get(opts, :title)
    units = Keyword.get(opts, :units)

    rows = Enum.map(points, &normalize_point/1)

    if Enum.any?(rows, &is_nil/1) do
      {:safe, ""}
    else
      do_line_plot(rows, width, height, title, units)
    end
  end

  def line_plot(_points, _opts), do: {:safe, ""}

  # --------------------------------------------------------------------------
  # Internal
  # --------------------------------------------------------------------------

  defp do_line_plot(rows, width, height, title, units) do
    dataset = Dataset.new(rows, ["date", "value"])

    plot_content =
      LinePlot.new(dataset,
        mapping: %{x_col: "date", y_cols: ["value"]},
        smoothed: false,
        stroke_width: "2"
      )

    plot =
      Plot.new(width, height, plot_content)
      |> Plot.titles(title || "", "")
      |> Plot.axis_labels("", units || "")

    Plot.to_svg(plot)
  end

  defp normalize_point(%{} = p) do
    case {fetch(p, :date, "date"), fetch(p, :value, "value")} do
      {%Date{} = d, v} when is_number(v) -> [date_to_utc_dt(d), v]
      {%DateTime{} = dt, v} when is_number(v) -> [dt, v]
      {%NaiveDateTime{} = ndt, v} when is_number(v) -> [ndt, v]
      {bin, v} when is_binary(bin) and is_number(v) -> normalize_with_date_string(bin, v)
      _ -> nil
    end
  end

  defp normalize_point(_), do: nil

  defp normalize_with_date_string(bin, v) do
    case Date.from_iso8601(bin) do
      {:ok, d} -> [date_to_utc_dt(d), v]
      _ -> nil
    end
  end

  defp date_to_utc_dt(%Date{} = d) do
    {:ok, dt} = DateTime.new(d, ~T[00:00:00], "Etc/UTC")
    dt
  end

  defp fetch(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, v} -> v
      :error -> Map.get(map, string_key)
    end
  end
end
