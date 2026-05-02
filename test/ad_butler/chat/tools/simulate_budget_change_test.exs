defmodule AdButler.Chat.Tools.SimulateBudgetChangeTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Chat.Tools.SimulateBudgetChange
  alias AdButler.InsightsHelpers
  alias AdButler.Repo

  setup do
    # Make sure today's partition exists; SimulateBudgetChange aggregates over
    # the past 30 days so we seed days back through 29.
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE)::DATE)")
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '7 days')::DATE)")
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '14 days')::DATE)")
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '21 days')::DATE)")
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '28 days')::DATE)")
    :ok
  end

  defp build_ad_set_for_user(user, ad_set_overrides \\ []) do
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    campaign = insert(:campaign, ad_account: ad_account)

    ad_set =
      insert(
        :ad_set,
        Keyword.merge(
          [ad_account: ad_account, campaign: campaign, daily_budget_cents: 10_000],
          ad_set_overrides
        )
      )

    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)
    {ad_set, ad}
  end

  defp run_tool(user_id, params) do
    SimulateBudgetChange.run(params, %{session_context: %{user_id: user_id}})
  end

  describe "tenant isolation" do
    test "user_b cannot run the tool on user_a's ad set — returns :not_found" do
      user_a = insert(:user)
      user_b = insert(:user)
      _ = insert(:meta_connection, user: user_b)
      {ad_set_a, _ad_a} = build_ad_set_for_user(user_a)

      assert {:error, :not_found} =
               run_tool(user_b.id, %{ad_set_id: ad_set_a.id, new_budget_cents: 20_000})
    end
  end

  describe "happy path shape" do
    test "returns the expected payload keys" do
      user = insert(:user)
      {ad_set, ad} = build_ad_set_for_user(user)

      # Seed enough data to land in :medium confidence (≥ 7 distinct days).
      for d <- 0..9 do
        InsightsHelpers.insert_daily(ad, d, %{
          spend_cents: 1_000,
          impressions: 500,
          frequency: Decimal.new("1.5")
        })
      end

      assert {:ok, payload} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})

      assert %{
               ad_set_id: _,
               current_budget_cents: 10_000,
               new_budget_cents: 20_000,
               observed_30d: %{spend_cents: _, impressions: _, days_with_data: _},
               projected_reach: reach,
               projected_frequency: freq,
               saturation_warning: warn?,
               confidence: confidence
             } = payload

      assert is_integer(reach)
      assert is_number(freq)
      assert is_boolean(warn?)
      assert confidence in [:low, :medium, :high]
    end
  end

  describe "confidence band selection" do
    test ":low when fewer than 7 days of data" do
      user = insert(:user)
      {ad_set, ad} = build_ad_set_for_user(user)

      for d <- 0..2,
          do:
            InsightsHelpers.insert_daily(ad, d, %{
              spend_cents: 1_000,
              impressions: 500,
              frequency: Decimal.new("1.0")
            })

      assert {:ok, %{confidence: :low}} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})
    end

    test ":medium between 7 and 20 days" do
      user = insert(:user)
      {ad_set, ad} = build_ad_set_for_user(user)

      for d <- 0..9,
          do:
            InsightsHelpers.insert_daily(ad, d, %{
              spend_cents: 1_000,
              impressions: 500,
              frequency: Decimal.new("1.0")
            })

      assert {:ok, %{confidence: :medium}} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})
    end

    test ":high at 21 or more days" do
      user = insert(:user)
      {ad_set, ad} = build_ad_set_for_user(user)

      for d <- 0..24,
          do:
            InsightsHelpers.insert_daily(ad, d, %{
              spend_cents: 1_000,
              impressions: 500,
              frequency: Decimal.new("1.0")
            })

      assert {:ok, %{confidence: :high}} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})
    end

    test "exact 7-day boundary lands :medium (catches >= 7 → > 7 off-by-one)" do
      # Production guard: confidence(days) when days >= 7, do: :medium. A flip
      # to `> 7` would silently downgrade 7-day data to :low.
      user = insert(:user)
      {ad_set, ad} = build_ad_set_for_user(user)

      Repo.query!("SELECT create_insights_partition((CURRENT_DATE - INTERVAL '6 days')::DATE)")

      for d <- 0..6,
          do:
            InsightsHelpers.insert_daily(ad, d, %{
              spend_cents: 100,
              impressions: 50,
              frequency: Decimal.new("1.0")
            })

      assert {:ok, %{confidence: :medium}} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})
    end

    test "exact 21-day boundary lands :high (catches >= 21 → > 21 off-by-one)" do
      user = insert(:user)
      {ad_set, ad} = build_ad_set_for_user(user)

      for d <- 0..20,
          do:
            InsightsHelpers.insert_daily(ad, d, %{
              spend_cents: 100,
              impressions: 50,
              frequency: Decimal.new("1.0")
            })

      assert {:ok, %{confidence: :high}} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})
    end
  end

  describe "zero current budget" do
    test "does not raise; returns a sensible numeric projection" do
      # `budget_ratio/2` divides by current_budget; the zero-budget head clause
      # short-circuits to 1.0 so the simulation must NOT raise. The projection
      # values must be finite (not NaN, not :infinity).
      user = insert(:user)

      {ad_set, ad} =
        build_ad_set_for_user(user, daily_budget_cents: nil, lifetime_budget_cents: nil)

      InsightsHelpers.insert_daily(ad, 0, %{
        spend_cents: 1_000,
        impressions: 500,
        frequency: Decimal.new("1.0")
      })

      assert {:ok, payload} =
               run_tool(user.id, %{ad_set_id: ad_set.id, new_budget_cents: 20_000})

      assert payload.current_budget_cents == 0
      assert is_integer(payload.projected_reach)
      assert is_number(payload.projected_frequency)
      # Float.is_finite? was added in 1.18; use the tagged-tuple negation.
      refute payload.projected_reach == :infinity
    end
  end

  describe "schema validation" do
    test "rejects missing ad_set_id" do
      assert {:error, _} =
               SimulateBudgetChange.validate_params(%{new_budget_cents: 100})
    end

    test "rejects negative new_budget_cents (pos_integer schema)" do
      assert {:error, _} =
               SimulateBudgetChange.validate_params(%{
                 ad_set_id: "abc",
                 new_budget_cents: -1
               })
    end
  end
end
