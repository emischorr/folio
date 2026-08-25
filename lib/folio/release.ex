defmodule Folio.Release do
  @moduledoc """
  Tasks that run inside a release, where Mix is not available.

  Invoke as `bin/folio eval "Folio.Release.migrate()"` before starting the
  app, so `Folio.Bootstrap` always runs against a fully migrated database.
  """

  @app :folio

  @doc "Runs all pending repo migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls the given repo back to the given migration version."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _fun_return, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
