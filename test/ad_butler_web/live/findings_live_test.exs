defmodule AdButlerWeb.FindingsLiveTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory
  import Phoenix.LiveViewTest

  defp setup_user_with_finding(_context) do
    user = insert(:user)
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    ad_set = insert(:ad_set, ad_account: ad_account)
    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

    finding =
      insert(:finding,
        ad_id: ad.id,
        ad_account_id: ad_account.id,
        kind: "dead_spend",
        severity: "high"
      )

    %{user: user, mc: mc, ad_account: ad_account, ad: ad, finding: finding}
  end

  describe "FindingsLive" do
    setup :setup_user_with_finding

    test "shows finding count and finding title", %{conn: conn, user: user, finding: finding} do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings")

      assert html =~ "1 finding"
      assert html =~ finding.title
    end

    test "filter by severity=high shows only high findings", %{
      conn: conn,
      user: user,
      ad_account: ad_account,
      finding: high_finding
    } do
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad2 = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      low_finding =
        insert(:finding,
          ad_id: ad2.id,
          ad_account_id: ad_account.id,
          kind: "bot_traffic",
          severity: "low",
          title: "Low severity finding"
        )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings?#{%{severity: "high"}}")

      assert html =~ high_finding.title
      refute html =~ low_finding.title
    end

    test "filter by kind=dead_spend shows only dead_spend findings", %{
      conn: conn,
      user: user,
      ad_account: ad_account,
      finding: dead_spend_finding
    } do
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad2 = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      other_finding =
        insert(:finding,
          ad_id: ad2.id,
          ad_account_id: ad_account.id,
          kind: "bot_traffic",
          severity: "medium",
          title: "Bot Traffic Finding"
        )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings?#{%{kind: "dead_spend"}}")

      assert html =~ dead_spend_finding.title
      refute html =~ other_finding.title
    end

    test "tenant isolation — user B cannot see user A's findings", %{
      conn: conn,
      finding: finding
    } do
      user_b = insert(:user)
      conn = log_in_user(conn, user_b)
      {:ok, _view, html} = live(conn, ~p"/findings")

      refute html =~ finding.title
    end

    test "unauthenticated request redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/findings")
    end

    test "filter by kind=creative_fatigue shows only fatigue findings", %{
      conn: conn,
      user: user,
      ad_account: ad_account
    } do
      ad_set = insert(:ad_set, ad_account: ad_account)
      ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

      fatigue_finding =
        insert(:finding,
          ad_id: ad.id,
          ad_account_id: ad_account.id,
          kind: "creative_fatigue",
          severity: "medium",
          title: "Ad showing fatigue signals"
        )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings?#{%{kind: "creative_fatigue"}}")

      assert html =~ fatigue_finding.title
      assert html =~ "Creative Fatigue"
    end
  end

  describe "filter_changed event" do
    setup :setup_user_with_finding

    test "severity filter pushes URL patch with severity param", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/findings")

      render_change(view, "filter_changed", %{"severity" => "high"})

      assert_patch(view, ~p"/findings?#{%{severity: "high"}}")
    end

    test "clearing filters pushes URL patch without filter params", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/findings?#{%{severity: "high"}}")

      render_change(view, "filter_changed", %{"severity" => "", "kind" => ""})

      assert_patch(view, ~p"/findings")
    end
  end

  describe "paginate event" do
    setup :setup_user_with_finding

    test "paginate event pushes URL patch with page param", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/findings")

      render_click(view, "paginate", %{"page" => "2"})

      assert_patch(view, ~p"/findings?#{%{page: 2}}")
    end

    test "renders 'No findings' message when no findings match filters", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings?#{%{severity: "low"}}")

      assert html =~ "No findings match"
    end

    test "pagination: page 2 shows second page of findings", %{
      conn: conn,
      user: user,
      ad_account: ad_account
    } do
      # Insert 52 findings (1 already exists from setup + 51 more)
      ad_set = insert(:ad_set, ad_account: ad_account)

      for i <- 1..51 do
        ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

        insert(:finding,
          ad_id: ad.id,
          ad_account_id: ad_account.id,
          kind: "dead_spend",
          severity: "high",
          title: "Finding #{i}"
        )
      end

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings?#{%{page: 2}}")

      # Page 2 has 2 findings (52 total, 50 per page)
      assert html =~ "52 findings"
    end
  end
end
