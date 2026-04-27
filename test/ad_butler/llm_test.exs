defmodule AdButler.LLMTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.LLM

  defp usage_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        purpose: "chat_response",
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        input_tokens: 100,
        output_tokens: 50,
        cached_tokens: 0,
        cost_cents_input: 10,
        cost_cents_output: 15,
        cost_cents_total: 25,
        status: "success",
        request_id: "req_#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp insert_usage!(user, overrides \\ %{}) do
    :ok = LLM.insert_usage(usage_attrs(user, overrides))
  end

  describe "insert_usage/1" do
    test "inserts a usage row and returns :ok" do
      user = insert(:user)
      assert :ok = LLM.insert_usage(usage_attrs(user))
    end

    test "is idempotent on duplicate request_id" do
      user = insert(:user)
      attrs = usage_attrs(user, %{request_id: "dup_req"})
      assert :ok = LLM.insert_usage(attrs)
      assert :ok = LLM.insert_usage(attrs)
    end

    test "returns {:error, changeset} on invalid attrs" do
      assert {:error, cs} = LLM.insert_usage(%{purpose: "chat_response"})
      assert cs.errors[:user_id]
    end
  end

  describe "list_usage_for_user/2" do
    test "returns rows belonging to the user" do
      user = insert(:user)
      insert_usage!(user)
      insert_usage!(user)

      rows = LLM.list_usage_for_user(user)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.user_id == user.id))
    end

    test "tenant isolation: user B cannot see user A rows" do
      user_a = insert(:user)
      user_b = insert(:user)
      insert_usage!(user_a)

      assert LLM.list_usage_for_user(user_b) == []
    end

    test "filters by :purpose" do
      user = insert(:user)
      insert_usage!(user, %{purpose: "chat_response"})
      insert_usage!(user, %{purpose: "embedding"})

      rows = LLM.list_usage_for_user(user, purpose: "chat_response")
      assert length(rows) == 1
      assert hd(rows).purpose == "chat_response"
    end

    test "filters by :provider" do
      user = insert(:user)
      insert_usage!(user, %{provider: "anthropic"})
      insert_usage!(user, %{provider: "openai"})

      rows = LLM.list_usage_for_user(user, provider: "openai")
      assert length(rows) == 1
      assert hd(rows).provider == "openai"
    end

    test "filters by :status" do
      user = insert(:user)
      insert_usage!(user, %{status: "success"})
      insert_usage!(user, %{status: "error"})

      rows = LLM.list_usage_for_user(user, status: "error")
      assert length(rows) == 1
      assert hd(rows).status == "error"
    end

    test "respects :limit option" do
      user = insert(:user)
      for _ <- 1..5, do: insert_usage!(user)

      rows = LLM.list_usage_for_user(user, limit: 3)
      assert length(rows) == 3
    end
  end

  describe "total_cost_for_user/1" do
    test "sums cost columns correctly" do
      user = insert(:user)
      insert_usage!(user, %{cost_cents_input: 10, cost_cents_output: 15, cost_cents_total: 25})
      insert_usage!(user, %{cost_cents_input: 20, cost_cents_output: 30, cost_cents_total: 50})

      result = LLM.total_cost_for_user(user)
      assert result.input_cents == 30
      assert result.output_cents == 45
      assert result.total_cents == 75
    end

    test "returns zeros when user has no rows" do
      user = insert(:user)
      result = LLM.total_cost_for_user(user)
      assert result == %{input_cents: 0, output_cents: 0, total_cents: 0}
    end

    test "tenant isolation: costs are scoped per user" do
      user_a = insert(:user)
      user_b = insert(:user)
      insert_usage!(user_a, %{cost_cents_total: 100})

      result = LLM.total_cost_for_user(user_b)
      assert result.total_cents == 0
    end
  end

  describe "get_usage!/2" do
    test "returns the row for the owning user" do
      user = insert(:user)
      :ok = LLM.insert_usage(usage_attrs(user))
      [row] = LLM.list_usage_for_user(user)

      fetched = LLM.get_usage!(user, row.id)
      assert fetched.id == row.id
    end

    test "raises for a different user" do
      user_a = insert(:user)
      user_b = insert(:user)
      :ok = LLM.insert_usage(usage_attrs(user_a))
      [row] = LLM.list_usage_for_user(user_a)

      assert_raise Ecto.NoResultsError, fn ->
        LLM.get_usage!(user_b, row.id)
      end
    end
  end
end
