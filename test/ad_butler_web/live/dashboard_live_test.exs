defmodule AdButlerWeb.DashboardLiveTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory
  import Phoenix.LiveViewTest

  describe "DashboardLive" do
    setup do
      user = insert(:user)
      mc = insert(:meta_connection, user: user)
      ad_account = insert(:ad_account, meta_connection: mc)
      %{user: user, mc: mc, ad_account: ad_account}
    end

    test "mounts and shows user email", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      html = render(view)
      assert html =~ user.email
    end

    test "shows ad account count of 1", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      html = render(view)
      assert html =~ ~r/<dd[^>]*>\s*1\s*<\/dd>/
      assert html =~ "Ad Accounts"
    end

    test "shows ad account name in table", %{conn: conn, user: user, ad_account: aa} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      html = render(view)
      assert html =~ aa.name
    end

    test "empty state renders Connect Meta Account link when no accounts", %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Connect Meta Account"
      assert html =~ ~p"/auth/meta"
    end

    test "unauthenticated request redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dashboard")
    end

    test "logout link renders with method=delete and href /auth/logout", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ ~p"/auth/logout"
      assert html =~ "data-method=\"delete\""
    end
  end
end
