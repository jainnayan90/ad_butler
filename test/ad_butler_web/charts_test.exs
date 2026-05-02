defmodule AdButlerWeb.ChartsTest do
  use ExUnit.Case, async: true

  alias AdButlerWeb.Charts

  describe "line_plot/2" do
    test "returns a {:safe, iolist} containing an SVG for a 7-point series" do
      points =
        for i <- 1..7 do
          %{date: Date.add(~D[2026-01-01], i), value: i * 1.5}
        end

      assert {:safe, iodata} = Charts.line_plot(points, title: "spend", units: "USD")
      svg = IO.iodata_to_binary(iodata)

      assert svg =~ "<svg"
      assert svg =~ "</svg>"
    end

    test "accepts ISO date strings (string-keyed maps from JSONB)" do
      points = [
        %{"date" => "2026-01-01", "value" => 10},
        %{"date" => "2026-01-02", "value" => 12}
      ]

      assert {:safe, iodata} = Charts.line_plot(points)
      assert IO.iodata_to_binary(iodata) =~ "<svg"
    end

    test "treats zero values as legitimate data (not missing)" do
      points = [
        %{date: ~D[2026-01-01], value: 0},
        %{date: ~D[2026-01-02], value: 5}
      ]

      assert {:safe, iodata} = Charts.line_plot(points)
      assert IO.iodata_to_binary(iodata) =~ "<svg"
    end

    test "returns empty safe tuple for empty input" do
      assert {:safe, ""} = Charts.line_plot([])
    end

    test "returns empty safe tuple for malformed input" do
      assert {:safe, ""} = Charts.line_plot([%{}])
      assert {:safe, ""} = Charts.line_plot([%{date: "not-a-date", value: 1}])
      assert {:safe, ""} = Charts.line_plot(:not_a_list)
    end
  end
end
