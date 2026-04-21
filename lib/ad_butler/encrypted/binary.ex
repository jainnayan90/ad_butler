defmodule AdButler.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: AdButler.Vault
end
