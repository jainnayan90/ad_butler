defmodule AdButler.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migrations.up(version: 14)
  end

  def down do
    Oban.Migrations.down(version: 14)
  end
end
