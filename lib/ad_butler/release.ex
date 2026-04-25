defmodule AdButler.Release do
  @moduledoc """
  Mix-free database migration helpers for use inside a compiled release.

  These functions are called from the release `eval` command (e.g.
  `ad_butler eval "AdButler.Release.migrate()"`) because `mix ecto.migrate` is
  not available in production releases.
  """

  @app :ad_butler

  @doc "Runs all pending `up` migrations for every configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Rolls back `repo` to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
