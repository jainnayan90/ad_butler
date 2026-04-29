defmodule AdButler.Notifications.DigestMailerTest do
  use ExUnit.Case, async: true

  alias AdButler.Notifications.DigestMailer

  defp build_finding(severity, title \\ "Test finding") do
    %{severity: severity, title: title}
  end

  describe "build/4 with total_count" do
    test "text body includes overflow trailer when total_count exceeds findings length" do
      user = %{email: "test@example.com", name: "Test User"}
      findings = [build_finding("high"), build_finding("medium")]

      email = DigestMailer.build(user, findings, "daily", 10)

      assert email.text_body =~ "and 8 more findings"
      assert email.html_body =~ "and 8 more findings"
    end

    test "no overflow trailer when total_count equals findings length" do
      user = %{email: "test@example.com", name: "Test User"}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily", 1)

      refute email.text_body =~ "more findings"
      refute email.html_body =~ "more findings"
    end

    test "subject uses total_count instead of findings length" do
      user = %{email: "test@example.com", name: "Test User"}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily", 42)

      assert email.subject =~ "42"
    end
  end

  describe "build/3 display name" do
    test "strips CRLF from name to prevent header injection" do
      user = %{email: "test@example.com", name: "Bad\r\nActor"}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      [{display, _addr}] = email.to
      refute display =~ "\r"
      refute display =~ "\n"
    end

    test "falls back to email when name is all whitespace/CRLF" do
      user = %{email: "test@example.com", name: "\r\n\r\n"}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      [{display, to_addr}] = email.to
      assert display == to_addr
    end

    test "truncates display name to 100 characters" do
      long_name = String.duplicate("A", 150)
      user = %{email: "test@example.com", name: long_name}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      [{display, _addr}] = email.to
      assert String.length(display) == 100
    end
  end

  describe "build/3" do
    test "returns an email with correct to address and display name" do
      user = %{email: "test@example.com", name: "Ada Lovelace"}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      [{display, to_addr}] = email.to
      assert to_addr == "test@example.com"
      assert display == "Ada Lovelace"
    end

    test "falls back to email as display name when name is nil" do
      user = %{email: "test@example.com", name: nil}
      findings = [build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      [{display, to_addr}] = email.to
      assert to_addr == "test@example.com"
      assert display == "test@example.com"
    end

    test "sets from address to noreply@adbutler.app" do
      user = %{email: "test@example.com", name: "Test User"}
      email = DigestMailer.build(user, [build_finding("high")], "weekly")

      {_name, from_addr} = email.from
      assert from_addr == "noreply@adbutler.app"
    end

    test "subject contains 'high-severity' when any finding is high" do
      user = %{email: "test@example.com", name: "Test User"}
      findings = [build_finding("medium"), build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      assert email.subject =~ "high-severity"
    end

    test "subject contains 'medium-severity' when all findings are medium" do
      user = %{email: "test@example.com", name: "Test User"}
      findings = [build_finding("medium"), build_finding("medium")]

      email = DigestMailer.build(user, findings, "weekly")

      assert email.subject =~ "medium-severity"
    end

    test "subject includes the period" do
      user = %{email: "test@example.com", name: "Test User"}
      email = DigestMailer.build(user, [build_finding("high")], "daily")
      assert email.subject =~ "daily"

      email2 = DigestMailer.build(user, [build_finding("high")], "weekly")
      assert email2.subject =~ "weekly"
    end

    test "subject includes the finding count" do
      user = %{email: "test@example.com", name: "Test User"}
      findings = [build_finding("high"), build_finding("medium"), build_finding("high")]

      email = DigestMailer.build(user, findings, "daily")

      assert email.subject =~ "3"
    end

    test "text body is non-empty and contains finding title" do
      user = %{email: "test@example.com", name: "Test User"}
      email = DigestMailer.build(user, [build_finding("high", "Suspicious spend")], "daily")

      assert String.length(email.text_body) > 0
      assert email.text_body =~ "Suspicious spend"
    end

    test "html body is non-empty and contains finding title" do
      user = %{email: "test@example.com", name: "Test User"}
      email = DigestMailer.build(user, [build_finding("medium", "CPA explosion")], "weekly")

      assert String.length(email.html_body) > 0
      assert email.html_body =~ "CPA explosion"
    end
  end
end
