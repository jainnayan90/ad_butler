defmodule AdButler.Encrypted.Binary do
  @moduledoc """
  Custom Ecto type that transparently encrypts and decrypts binary (string) fields
  via `AdButler.Vault`. Use as the field type in schemas that require at-rest
  encryption (e.g. `access_token` on `MetaConnection`).
  """

  use Cloak.Ecto.Binary, vault: AdButler.Vault
end
