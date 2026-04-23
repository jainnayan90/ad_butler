defmodule AdButler.Vault do
  @moduledoc """
  Cloak vault for field-level encryption of sensitive database columns.

  Encryption keys and the active cipher are configured in `config/runtime.exs`.
  Used by `AdButler.Encrypted.Binary` to transparently encrypt/decrypt
  `access_token` values stored in `meta_connections`.
  """

  use Cloak.Vault, otp_app: :ad_butler
end
