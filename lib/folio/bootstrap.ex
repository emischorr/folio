defmodule Folio.Bootstrap do
  @moduledoc """
  Idempotent boot-time setup: ensures the Admin user and their default
  portfolio exist. Runs as a temporary `Task` in the supervision tree, so it
  also works in releases where `seeds.exs` is unavailable.

  Skips (with a warning) when migrations are pending, so a fresh checkout can
  boot before `mix ecto.migrate`; the next boot completes the setup.
  """

  require Logger

  alias Folio.Accounts
  alias Folio.Portfolios
  alias Folio.Repo

  @default_portfolio_name "Portfolio"

  @doc "Runs the bootstrap. Safe to call repeatedly."
  @spec run() :: :ok | :skipped
  def run do
    config = Application.get_env(:folio, __MODULE__, [])

    cond do
      not Keyword.get(config, :enabled, true) ->
        :skipped

      pending_migrations?() ->
        Logger.warning("Folio.Bootstrap skipped: pending migrations - run mix ecto.migrate")
        :skipped

      true ->
        {:ok, _result} =
          Repo.transaction(fn ->
            ensure_admin_with_portfolio(Keyword.get(config, :admin_password, "admin"))
          end)

        :ok
    end
  end

  defp ensure_admin_with_portfolio(admin_password) do
    admin = Accounts.ensure_admin(admin_password)

    unless Portfolios.owns_portfolio?(admin.id) do
      {:ok, _portfolio} =
        Portfolios.create_portfolio(
          %{name: @default_portfolio_name, base_currency: "EUR"},
          admin.id
        )

      Logger.info("Folio.Bootstrap created default user and portfolio")
    end

    :ok
  end

  defp pending_migrations? do
    Repo
    |> Ecto.Migrator.migrations()
    |> Enum.any?(fn {status, _version, _name} -> status == :down end)
  end
end
