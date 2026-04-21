defmodule AdButler.ErrorHelpers do
  @doc """
  Sanitizes error terms for safe logging — returns only the tag atom, never
  raw structs or binaries that may embed secrets (e.g. Mint transport errors
  whose inspect output could include request URLs containing access tokens).
  """
  def safe_reason({tag, _}) when is_atom(tag), do: tag
  def safe_reason(reason) when is_atom(reason), do: reason
  def safe_reason(_), do: :unknown
end
