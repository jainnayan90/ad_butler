defmodule AdButler.Chat.LogRedactorTest do
  use ExUnit.Case, async: true

  alias AdButler.Chat.LogRedactor

  describe "redact/1" do
    test "passes atoms through unchanged" do
      assert LogRedactor.redact(:timeout) == :timeout
      assert LogRedactor.redact(:rate_limited) == :rate_limited
      assert LogRedactor.redact(nil) == nil
    end

    test "reduces a 2-tuple with an atom tag to the tag" do
      assert LogRedactor.redact({:dns_error, "user-content-leak"}) == :dns_error
      assert LogRedactor.redact({:error, %{body: "secret"}}) == :error
    end

    test "reduces a 3-tuple with an atom tag to the tag (start_async exit shape)" do
      assert LogRedactor.redact({:exit, :normal, [{:some, :stack}]}) == :exit
      assert LogRedactor.redact({:badmatch, "leak", :stack}) == :badmatch
    end

    test "collapses maps to :unknown" do
      assert LogRedactor.redact(%{body: "user message"}) == :unknown
      assert LogRedactor.redact(%{}) == :unknown
    end

    test "collapses content-bearing strings to :unknown" do
      assert LogRedactor.redact("HTTP 429 — please retry") == :unknown
      assert LogRedactor.redact("") == :unknown
    end

    test "collapses tuples with non-atom tags to :unknown" do
      assert LogRedactor.redact({"dns_error", "leak"}) == :unknown
      assert LogRedactor.redact({1, 2, 3}) == :unknown
    end

    test "collapses other terms (numbers, lists, structs) to :unknown" do
      assert LogRedactor.redact(429) == :unknown
      assert LogRedactor.redact([:a, :b]) == :unknown
      assert LogRedactor.redact(%RuntimeError{message: "boom"}) == :unknown
    end
  end
end
