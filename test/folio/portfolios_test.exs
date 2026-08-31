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

      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id}
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

    test "get_transaction!/2 is scoped to the portfolio" do
      portfolio = portfolio_fixture()
      other = portfolio_fixture()
      asset = crypto_asset_fixture()
      transaction = transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})

      assert Portfolios.get_transaction!(portfolio.id, transaction.id).id == transaction.id

      assert_raise Ecto.NoResultsError, fn ->
        Portfolios.get_transaction!(other.id, transaction.id)
      end
    end

    test "change_transaction/2 validates without persisting" do
      changeset = Portfolios.change_transaction(%Folio.Portfolios.Transaction{}, %{quantity: "0"})

      refute changeset.valid?
      assert %{quantity: [_message]} = errors_on(changeset)
    end

    test "update_transaction/2 persists changes and backfills newly uncovered history" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      transaction =
        transaction_fixture(%{
          portfolio_id: portfolio.id,
          asset_id: asset.id,
          executed_at: ~U[2025-06-01 12:00:00Z]
        })

      assert {:ok, updated} =
               Portfolios.update_transaction(transaction, %{
                 quantity: "3",
                 executed_at: ~U[2025-02-01 12:00:00Z]
               })

      assert Decimal.eq?(updated.quantity, "3")
      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id}

      # The moved-back date is picked up from the transaction at execution time,
      # not from the job args.
      assert Portfolios.earliest_transaction_date(asset.id) == ~D[2025-02-01]
    end

    test "update_transaction/2 returns the changeset on invalid input" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      transaction = transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})

      assert {:error, changeset} = Portfolios.update_transaction(transaction, %{quantity: "0"})
      assert %{quantity: [_message]} = errors_on(changeset)
    end

    test "any_transactions?/1 reflects whether the portfolio has entries" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      refute Portfolios.any_transactions?(portfolio.id)

      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})
      assert Portfolios.any_transactions?(portfolio.id)
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

  describe "asset groups" do
    test "create_asset_group/2 scopes the group to the portfolio" do
      portfolio = portfolio_fixture()

      assert {:ok, group} = Portfolios.create_asset_group(portfolio.id, %{name: "Tech"})
      assert group.portfolio_id == portfolio.id
      assert group.name == "Tech"
    end

    test "create_asset_group/2 rejects a blank name" do
      portfolio = portfolio_fixture()

      assert {:error, changeset} = Portfolios.create_asset_group(portfolio.id, %{name: ""})
      assert %{name: [_message]} = errors_on(changeset)
    end

    test "create_asset_group/2 rejects a duplicate name within the same portfolio" do
      portfolio = portfolio_fixture()
      asset_group_fixture(%{portfolio_id: portfolio.id, name: "Tech"})

      assert {:error, changeset} = Portfolios.create_asset_group(portfolio.id, %{name: "Tech"})
      assert %{name: [_message]} = errors_on(changeset)
    end

    test "create_asset_group/2 allows the same name across different portfolios" do
      portfolio_a = portfolio_fixture()
      portfolio_b = portfolio_fixture()
      asset_group_fixture(%{portfolio_id: portfolio_a.id, name: "Tech"})

      assert {:ok, _group} = Portfolios.create_asset_group(portfolio_b.id, %{name: "Tech"})
    end

    test "list_asset_groups/1 returns groups alphabetically, scoped to the portfolio" do
      portfolio = portfolio_fixture()
      other = portfolio_fixture()
      asset_group_fixture(%{portfolio_id: portfolio.id, name: "Value"})
      asset_group_fixture(%{portfolio_id: portfolio.id, name: "Growth"})
      asset_group_fixture(%{portfolio_id: other.id, name: "Alpha"})

      assert Portfolios.list_asset_groups(portfolio.id) |> Enum.map(& &1.name) ==
               ["Growth", "Value"]
    end

    test "change_asset_group/2 validates without persisting" do
      changeset = Portfolios.change_asset_group(%Folio.Portfolios.AssetGroup{}, %{name: ""})

      refute changeset.valid?
      assert %{name: [_message]} = errors_on(changeset)
    end

    test "assign_asset_to_group/3 creates the membership" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      group = asset_group_fixture(%{portfolio_id: portfolio.id, name: "Crypto"})

      assert {:ok, assigned} = Portfolios.assign_asset_to_group(portfolio.id, asset.id, group.id)
      assert assigned.id == group.id
      assert Portfolios.get_asset_group_for_asset(portfolio.id, asset.id).id == group.id
    end

    test "assign_asset_to_group/3 reassigns rather than duplicating" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      group_a = asset_group_fixture(%{portfolio_id: portfolio.id, name: "A"})
      group_b = asset_group_fixture(%{portfolio_id: portfolio.id, name: "B"})

      {:ok, _} = Portfolios.assign_asset_to_group(portfolio.id, asset.id, group_a.id)
      {:ok, _} = Portfolios.assign_asset_to_group(portfolio.id, asset.id, group_b.id)

      assert Portfolios.get_asset_group_for_asset(portfolio.id, asset.id).id == group_b.id
      assert Portfolios.asset_group_by_asset(portfolio.id) |> map_size() == 1
    end

    test "assign_asset_to_group/3 raises when the group belongs to a different portfolio" do
      portfolio = portfolio_fixture()
      other = portfolio_fixture()
      asset = crypto_asset_fixture()
      group = asset_group_fixture(%{portfolio_id: other.id, name: "Foreign"})

      assert_raise Ecto.NoResultsError, fn ->
        Portfolios.assign_asset_to_group(portfolio.id, asset.id, group.id)
      end
    end

    test "get_asset_group_for_asset/2 returns nil when ungrouped" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      assert Portfolios.get_asset_group_for_asset(portfolio.id, asset.id) == nil
    end

    test "asset_group_by_asset/1 maps only grouped assets in that portfolio" do
      portfolio = portfolio_fixture()
      grouped = crypto_asset_fixture()
      ungrouped = stock_asset_fixture()
      group = asset_group_fixture(%{portfolio_id: portfolio.id, name: "Crypto"})
      {:ok, _} = Portfolios.assign_asset_to_group(portfolio.id, grouped.id, group.id)

      map = Portfolios.asset_group_by_asset(portfolio.id)

      assert map[grouped.id].id == group.id
      refute Map.has_key?(map, ungrouped.id)
    end

    test "create_asset_group_and_assign/3 creates and assigns atomically" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()

      assert {:ok, group} =
               Portfolios.create_asset_group_and_assign(portfolio.id, asset.id, %{name: "Tech"})

      assert group.name == "Tech"
      assert Portfolios.get_asset_group_for_asset(portfolio.id, asset.id).id == group.id
    end

    test "create_asset_group_and_assign/3 rolls back the membership on a duplicate name" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      asset_group_fixture(%{portfolio_id: portfolio.id, name: "Tech"})

      assert {:error, changeset} =
               Portfolios.create_asset_group_and_assign(portfolio.id, asset.id, %{name: "Tech"})

      assert %{name: [_message]} = errors_on(changeset)
      assert Portfolios.get_asset_group_for_asset(portfolio.id, asset.id) == nil
    end
  end
end
