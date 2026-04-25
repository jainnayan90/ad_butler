defmodule AdButler.Workers.ObanBehaviour do
  @moduledoc """
  Behaviour for the subset of `Oban` functions used by sweep workers.
  Extracted to allow test injection via `Application.put_env(:ad_butler, :oban_mod, MockMod)`.
  """

  @doc "Inserts multiple Oban job changesets in a single DB round-trip."
  @callback insert_all(list(Ecto.Changeset.t())) :: list(Oban.Job.t())
end
