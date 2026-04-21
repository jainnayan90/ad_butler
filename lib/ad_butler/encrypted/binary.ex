defmodule AdButler.Encrypted.Binary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: AdButler.Vault
end
