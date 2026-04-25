defmodule AdButlerWeb.CampaignsLiveTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory
  import Phoenix.LiveViewTest

  defp setup_user_with_campaigns(_context) do
    user = insert(:user)
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    active_campaign = insert(:campaign, ad_account: ad_account, status: "ACTIVE")
    paused_campaign = insert(:campaign, ad_account: ad_account, status: "PAUSED")

    %{
      user: user,
      mc: mc,
      ad_account: ad_account,
      active_campaign: active_campaign,
      paused_campaign: paused_campaign
    }
  end

  describe "CampaignsLive" do
    setup :setup_user_with_campaigns

    test "campaigns display correctly for authenticated user", %{
      conn: conn,
      user: user,
      active_campaign: ac,
      paused_campaign: pc
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/campaigns")
      assert html =~ ac.name
      assert html =~ pc.name
    end

    test "filter by ad_account_id shows only that account's campaigns", %{
      conn: conn,
      user: user,
      ad_account: aa,
      active_campaign: ac
    } do
      other_mc = insert(:meta_connection, user: user)
      other_aa = insert(:ad_account, meta_connection: other_mc)
      other_campaign = insert(:campaign, ad_account: other_aa, name: "Other Account Campaign")

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/campaigns?#{%{ad_account_id: aa.id}}")
      assert html =~ ac.name
      refute html =~ other_campaign.name
    end

    test "filter by status=ACTIVE shows only active campaigns", %{
      conn: conn,
      user: user,
      active_campaign: ac,
      paused_campaign: pc
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/campaigns?#{%{status: "ACTIVE"}}")
      assert html =~ ac.name
      refute html =~ pc.name
    end

    test "tenant isolation — user A cannot see user B's campaigns", %{
      conn: conn,
      active_campaign: ac
    } do
      user_b = insert(:user)
      conn = log_in_user(conn, user_b)
      {:ok, _view, html} = live(conn, ~p"/campaigns")
      refute html =~ ac.name
    end

    test "unauthenticated request redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/campaigns")
    end

    test "empty filter result renders No campaigns message without crashing", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/campaigns?#{%{status: "DELETED"}}")
      assert html =~ "No campaigns match your filters."
    end

    test "filter event pushes patch updating URL and filters campaigns", %{
      conn: conn,
      user: user,
      active_campaign: ac,
      paused_campaign: pc
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/campaigns")

      html = render_change(view, "filter", %{"status" => "ACTIVE", "ad_account_id" => ""})

      assert_patch(view, ~p"/campaigns?#{%{status: "ACTIVE"}}")
      assert html =~ ac.name
      refute html =~ pc.name
    end

    test "filter event with unknown status is rejected — not pushed to URL", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/campaigns")

      render_change(view, "filter", %{"status" => "UNKNOWN", "ad_account_id" => ""})

      assert_patch(view, ~p"/campaigns")
    end
  end
end
