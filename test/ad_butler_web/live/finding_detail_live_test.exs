defmodule AdButlerWeb.FindingDetailLiveTest do
  use AdButlerWeb.ConnCase, async: true

  import AdButler.Factory
  import Phoenix.LiveViewTest

  alias AdButler.Analytics
  alias AdButler.Analytics.Finding
  alias AdButler.Repo

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
        severity: "high",
        title: "Dead spend detected",
        body: "Ad has spent with zero conversions"
      )

    %{user: user, finding: finding, ad: ad}
  end

  describe "FindingDetailLive" do
    setup :setup_user_with_finding

    test "renders finding title, body, and severity", %{
      conn: conn,
      user: user,
      finding: finding
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings/#{finding.id}")

      assert html =~ finding.title
      assert html =~ finding.body
      assert html =~ "High"
      assert html =~ "Dead Spend"
    end

    test "renders Acknowledge button when not yet acknowledged", %{
      conn: conn,
      user: user,
      finding: finding
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings/#{finding.id}")

      assert html =~ "Acknowledge"
      refute html =~ "Acknowledged"
    end

    test "acknowledging a finding removes the button and shows Acknowledged", %{
      conn: conn,
      user: user,
      finding: finding
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/findings/#{finding.id}")

      html = render_click(view, "acknowledge")

      assert html =~ "Acknowledged"
      refute html =~ ~s(phx-click="acknowledge")

      persisted = Repo.get!(Finding, finding.id)
      assert persisted.acknowledged_at != nil
      assert persisted.acknowledged_by_user_id == user.id
    end

    test "renders health score when present", %{conn: conn, user: user, finding: finding, ad: ad} do
      insert(:ad_health_score, ad_id: ad.id, leak_score: Decimal.new("40.00"))

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings/#{finding.id}")

      assert html =~ "Leak Score"
      assert html =~ "40"
    end

    test "renders no health score message when absent", %{
      conn: conn,
      user: user,
      finding: finding
    } do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings/#{finding.id}")

      assert html =~ "No health score computed yet"
    end

    test "renders fatigue score and per-signal values when present", %{
      conn: conn,
      user: user,
      ad: ad,
      finding: dead_spend_finding
    } do
      insert(:ad_health_score,
        ad_id: ad.id,
        leak_score: nil,
        fatigue_score: Decimal.new("65.00"),
        fatigue_factors: %{
          "frequency_ctr_decay" => %{
            "weight" => 35,
            "values" => %{"frequency" => 4.5, "ctr_slope" => -1.2}
          },
          "quality_drop" => %{
            "weight" => 30,
            "values" => %{
              "from" => "above_average",
              "to" => "average",
              "from_date" => "2026-04-25"
            }
          }
        }
      )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings/#{dead_spend_finding.id}")

      assert html =~ "Fatigue Score"
      assert html =~ "65"
      assert html =~ "Frequency + CTR decay"
      assert html =~ "frequency 4.5"
      assert html =~ "Quality ranking drop"
      assert html =~ "above_average → average"
    end

    test "user B cannot acknowledge user A's finding via context", %{finding: finding} do
      user_b = insert(:user)
      _mc_b = insert(:meta_connection, user: user_b)

      assert {:error, :not_found} = Analytics.acknowledge_finding(user_b, finding.id)
    end

    test "tenant isolation — user B is redirected away from user A's finding", %{
      conn: conn,
      finding: finding
    } do
      user_b = insert(:user)
      conn = log_in_user(conn, user_b)

      assert {:error, {:live_redirect, %{to: "/findings"}}} =
               live(conn, ~p"/findings/#{finding.id}")
    end

    test "nonexistent finding ID redirects to /findings", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      bogus_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/findings"}}} =
               live(conn, ~p"/findings/#{bogus_id}")
    end

    test "back link navigates to /findings", %{conn: conn, user: user, finding: finding} do
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/findings/#{finding.id}")

      assert html =~ ~s(href="/findings")
    end

    test "unauthenticated request redirects to /", %{conn: conn, finding: finding} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/findings/#{finding.id}")
    end
  end
end
