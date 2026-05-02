defmodule AdButler.Chat.LogRedactor do
  @moduledoc """
  Reduces a free-form term to a non-content-bearing tag suitable for
  structured logging metadata.

  `start_async` exit reasons, LLM provider error bodies, and other
  third-party error tuples may echo user chat content (request bodies,
  prompt fragments). Logging them verbatim leaks PII and conversation
  contents into log aggregators.

  Use `redact/1` at every Logger call site that handles a generic
  `reason` term whose origin is the LLM client, an `:exit` from a Task,
  or any other path where the term may carry user content. Never
  round-trip the redacted value back to a user-facing channel — it is
  intentionally lossy.
  """

  @doc """
  Reduces `reason` to a safe tag.

  * Atoms pass through unchanged (`:timeout`, `:rate_limited`, `nil`, …).
  * Tagged tuples reduce to their leading atom (`{:dns_error, _}` → `:dns_error`,
    `{:exit, :normal, stack}` → `:exit`).
  * Anything else (maps with body strings, binary error messages,
    structs, integers) collapses to `:unknown`.
  """
  @spec redact(term()) :: atom()
  def redact(reason) when is_atom(reason), do: reason
  def redact({tag, _}) when is_atom(tag), do: tag
  def redact({tag, _, _}) when is_atom(tag), do: tag
  def redact(_), do: :unknown
end
