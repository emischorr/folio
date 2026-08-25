defmodule Folio.PortfoliosFixtures do
  @moduledoc "Test fixtures for portfolios and transactions. Transaction inserts are direct - no backfill jobs."

  alias Folio.AccountsFixtures
  alias Folio.Portfolios
  alias Folio.Portfolios.Portfolio
  alias Folio.Portfolios.Transaction
  alias Folio.Repo

  @doc "Creates a portfolio (default base currency EUR) owned by a fresh user."
  @spec portfolio_fixture(map()) :: Portfolio.t()
  def portfolio_fixture(attrs \\ %{}) do
    owner = Map.get_lazy(attrs, :owner, fn -> AccountsFixtures.user_fixture() end)

    {:ok, portfolio} =
      Portfolios.create_portfolio(
        %{
          name: Map.get(attrs, :name, "Portfolio #{System.unique_integer([:positive])}"),
          base_currency: Map.get(attrs, :base_currency, "EUR")
        },
        owner.id
      )

    portfolio
  end

  @doc """
  Inserts a transaction directly. Required: `:portfolio_id`, `:asset_id`.
  Numeric attrs accept anything `Decimal.new/1` accepts.
  """
  @spec transaction_fixture(map()) :: Transaction.t()
  def transaction_fixture(attrs) do
    defaults = %{
      type: :buy,
      executed_at: ~U[2025-01-15 10:00:00Z],
      quantity: "1",
      price_per_unit: "100",
      fee: "0",
      currency: "EUR"
    }

    attrs = Map.merge(defaults, attrs)

    Repo.insert!(%Transaction{
      portfolio_id: attrs.portfolio_id,
      asset_id: attrs.asset_id,
      type: attrs.type,
      executed_at: attrs.executed_at,
      quantity: Decimal.new(attrs.quantity),
      price_per_unit: Decimal.new(attrs.price_per_unit),
      fee: Decimal.new(attrs.fee),
      currency: attrs.currency,
      source: Map.get(attrs, :source),
      external_id: Map.get(attrs, :external_id)
    })
  end
end
