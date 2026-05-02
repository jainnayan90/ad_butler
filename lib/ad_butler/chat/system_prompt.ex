defmodule AdButler.Chat.SystemPrompt do
  @moduledoc """
  Loads the chat system prompt from `priv/prompts/system.md` at compile
  time and renders it with per-turn context (`today`, `user_id`,
  `ad_account_id`).

  The raw prompt is embedded via `@external_resource` so a change to the
  markdown file triggers a recompile (no stale-prompt-after-edit
  surprises). A compile-time assertion fails the build if the prompt
  exceeds the rough 2k-token ceiling (8 KB at ~4 chars/token).

  ## Prompt caching

  Anthropic prompt caching (ReqLLM 1.7+) keys the cache breakpoint on the
  LAST item of the request that has `cache_control`. Callers should pass
  the rendered prompt as the system message and apply `cache_control`
  there — see `Chat.Server` (Day 5 wiring).
  """

  @external_resource Path.join([:code.priv_dir(:ad_butler), "prompts", "system.md"])

  @raw_prompt File.read!(@external_resource)
  @max_bytes 8_000

  if byte_size(@raw_prompt) > @max_bytes do
    raise "priv/prompts/system.md exceeds #{@max_bytes} bytes (got #{byte_size(@raw_prompt)}). " <>
            "Keep the prompt under ~2k tokens — trim or split."
  end

  @doc "Returns the raw prompt template, before context interpolation."
  @spec raw() :: String.t()
  def raw, do: @raw_prompt

  @doc """
  Renders the system prompt with `context` interpolated. Required keys:

    * `:today` — usually `Date.utc_today()`
    * `:user_id` (currently unused in template; reserved)
    * `:ad_account_id` — optional; `nil` indicates cross-account session
      and renders as `"(none)"` (the documented sentinel).

  Returns the rendered string. Substitution is intentionally minimal
  (Mustache-style) — no Liquid / EEx — to avoid template-engine drift in
  prompt content.
  """
  @spec build(map()) :: String.t()
  def build(context) when is_map(context) do
    @raw_prompt
    |> String.replace("{{today}}", to_string(Map.get(context, :today, Date.utc_today())))
    |> String.replace("{{ad_account_id}}", render_ad_account_id(Map.get(context, :ad_account_id)))
  end

  defp render_ad_account_id(nil), do: "(none)"
  defp render_ad_account_id(id), do: to_string(id)
end
