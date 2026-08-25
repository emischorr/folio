defmodule Folio.PortfoliosTest do
  use Folio.DataCase, async: true

  import Folio.AccountsFixtures
  import Folio.AssetsFixtures
  import Folio.PortfoliosFixtures

  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates
  alias Folio.Portfolios

  describe "create_portfolio/2" do
    test "creates the portfolio with an owner membership atomically" do
      user = user_fixture()

      assert {:ok, portfolio} = Portfolios.create_portfolio(%{name: "Mine"}, user.id)
      assert portfolio.base_currency == "EUR"
      assert Portfolios.owns_portfolio?(user.id)
      assert [found] = Portfolios.list_portfolios(user.id)
      assert found.id == portfolio.id
    end

    test "rejects an invalid base currency" do
      user = user_fixture()

      assert {:error, changeset} =
               Portfolios.create_portfolio(%{name: "Bad", base_currency: "euros"}, user.id)

      assert %{base_currency: [_message]} = errors_on(changeset)
    end
  end

  describe "create_transaction/2" do
    test "defaults the currency to the asset's quote currency" do
      portfolio = portfolio_fixture()
      asset = stock_asset_fixture()

      assert {:ok, transaction} =
               Portfolios.create_transaction(portfolio.id, %{
                 asset_id: asset.id,
                 type: :buy,
                 executed_at: ~U[2025-06-01 12:00:00Z],
                 quantity: "2",
                 price_per_unit: "100.5"
               })

      assert transaction.currency == "USD"
      assert Decimal.eq?(transaction.fee, 0)
    end

    test "enqueues price and FX backfills covering the execution date" do
      portfolio = portfolio_fixture()
      asset = stock_asset_fixture()

      {:ok, _transaction} =
        Portfolios.create_transaction(portfolio.id, %{
          asset_id: asset.id,
          type: :buy,
          executed_at: ~U[2025-06-01 12:00:00Z],
          quantity: "1",
          price_per_unit: "10"
        })

      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id, from: "2025-06-01"}
      assert_enqueued worker: BackfillFxRates, args: %{currency: "USD", from: "2025-06-01"}
    end

    test "does not enqueue an FX backfill for EUR-quoted assets" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      {:ok, _transaction} =
        Portfolios.create_transaction(portfolio.id, %{
          asset_id: asset.id,
          type: :buy,
          executed_at: ~U[2025-06-01 12:00:00Z],
          quantity: "0.5",
          price_per_unit: "50000"
        })

      refute_enqueued worker: BackfillFxRates
    end

    test "skips the backfill when daily history already covers the date" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      Folio.MarketDataFixtures.seed_daily_prices(
        asset.id,
        ~D[2025-01-01],
        ~D[2025-01-05],
        "100",
        "1"
      )

      {:ok, _transaction} =
        Portfolios.create_transaction(portfolio.id, %{
          asset_id: asset.id,
          type: :buy,
          executed_at: ~U[2025-01-03 12:00:00Z],
          quantity: "1",
          price_per_unit: "10"
        })

      refute_enqueued worker: BackfillAssetPrices
    end

    test "rejects non-positive quantities and unknown assets" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      assert {:error, changeset} =
               Portfolios.create_transaction(portfolio.id, %{
                 asset_id: asset.id,
                 type: :sell,
                 executed_at: ~U[2025-06-01 12:00:00Z],
                 quantity: "0",
                 price_per_unit: "10"
               })

      assert %{quantity: [_message]} = errors_on(changeset)
    end
  end

  describe "transactions" do
    test "list_transactions/2 orders by execution time and filters by asset" do
      portfolio = portfolio_fixture()
      bitcoin = crypto_asset_fixture()
      stock = stock_asset_fixture()

      later =
        transaction_fixture(%{
          portfolio_id: portfolio.id,
          asset_id: bitcoin.id,
          executed_at: ~U[2025-03-01 00:00:00Z]
        })

      earlier =
        transaction_fixture(%{
          portfolio_id: portfolio.id,
          asset_id: stock.id,
          executed_at: ~U[2025-01-01 00:00:00Z],
          currency: "USD"
        })

      assert [first, second] = Portfolios.list_transactions(portfolio.id)
      assert first.id == earlier.id
      assert second.id == later.id

      assert [only] = Portfolios.list_transactions(portfolio.id, asset_id: bitcoin.id)
      assert only.id == later.id
    end

    test "delete_transaction/1 removes the row" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      transaction = transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})

      assert {:ok, _deleted} = Portfolios.delete_transaction(transaction)
      assert Portfolios.list_transactions(portfolio.id) == []
    end

    test "transaction_currencies/0 returns distinct currencies" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id, currency: "EUR"})
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id, currency: "USD"})
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id, currency: "USD"})

      assert Enum.sort(Portfolios.transaction_currencies()) == ["EUR", "USD"]
    end
  end
end
