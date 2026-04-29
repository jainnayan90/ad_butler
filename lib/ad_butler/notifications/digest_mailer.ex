defmodule AdButler.Notifications.DigestMailer do
  @moduledoc "Builds digest emails from audit findings."

  import Swoosh.Email

  @doc "Builds a digest email for `user` from the given `findings`, `period`, and optional `total_count`."
  @spec build(map(), list(), String.t(), non_neg_integer() | nil) :: Swoosh.Email.t()
  def build(user, findings, period, total_count \\ nil)
      when period in ["daily", "weekly"] do
    display_count = total_count || length(findings)
    subject = "AdButler: #{display_count} new #{severity_label(findings)} findings (#{period})"
    display_name = safe_display_name(user.name) || user.email

    new()
    |> to({display_name, user.email})
    |> from({"AdButler", "noreply@adbutler.app"})
    |> subject(subject)
    |> header("List-Unsubscribe", "<mailto:unsubscribe@adbutler.app>")
    |> text_body(build_text_body(findings, period, total_count))
    |> html_body(build_html_body(findings, period, total_count))
  end

  defp severity_label(findings) do
    if Enum.any?(findings, &(&1.severity == "high")), do: "high-severity", else: "medium-severity"
  end

  # Strip CRLF/null from Meta API names to prevent RFC 5322 header injection.
  # Returns nil (not "") so that the || user.email fallback triggers on blank names.
  defp safe_display_name(nil), do: nil

  defp safe_display_name(name) do
    stripped = name |> String.replace(~r/[\r\n\0]/, "") |> String.slice(0, 100)
    if stripped == "", do: nil, else: stripped
  end

  # Escape HTML special characters to prevent injection via Meta API ad names.
  defp h(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp build_text_body(findings, period, total_count) do
    header = "Your #{period} AdButler digest:\n\n"
    rows = Enum.map_join(findings, "\n", &"- [#{String.upcase(&1.severity)}] #{&1.title}")

    overflow =
      if total_count && total_count > length(findings) do
        "\n...and #{total_count - length(findings)} more findings."
      else
        ""
      end

    header <> rows <> overflow <> "\n\nLog in at https://adbutler.app/findings to review."
  end

  defp build_html_body(findings, period, total_count) do
    rows =
      Enum.map_join(findings, "", fn f ->
        badge_color = if f.severity == "high", do: "#dc2626", else: "#d97706"

        "<tr><td style='padding:8px'><span style='color:#{badge_color};font-weight:bold'>#{String.upcase(f.severity)}</span></td><td style='padding:8px'>#{h(f.title)}</td></tr>"
      end)

    overflow =
      if total_count && total_count > length(findings) do
        "<p style='color:#6b7280'>...and #{total_count - length(findings)} more findings.</p>"
      else
        ""
      end

    """
    <html><body style='font-family:sans-serif'>
    <h2>Your #{period} AdButler digest</h2>
    <table border='0' cellpadding='0' cellspacing='0'>#{rows}</table>
    #{overflow}<p><a href='https://adbutler.app/findings'>Review findings &#x2192;</a></p>
    </body></html>
    """
  end
end
