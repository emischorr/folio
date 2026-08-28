defmodule FolioWeb.DashboardLiveTest do
  use FolioWeb.ConnCase, async: false

  import Folio.AssetsFixtures
  import Folio.MarketDataFixtures
  import Folio.PortfoliosFixtures

  alias Folio.MarketData

  setup :bootstrap_default_user

  defp seed_holdings(%{portfolio: portfolio}) do
    today = Date.utc_today()
    bitcoin = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
    seed_daily_prices(bitcoin.id, Date.add(today, -40), today, "100", "1")

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: DateTime.new!(Date.add(today, -30), ~T[10:00:00], "Etc/UTC"),
      quantity: "2",
      price_per_unit: "110"
    })

    %{bitcoin: bitcoin}
  end

  describe "with holdings" do
    setup :seed_holdings

    test "mounts with the config defaults and pushes the chart series", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#window-1w[class*='bg-base-100']")
      assert has_element?(view, "#mode-value[class*='bg-base-100']")
      assert has_element?(view, "#currency-EUR[class*='bg-base-100']")

      assert_push_event(view, "chart:data", %{points: points, mode: "value"})
      assert [%{time: time, value: value} | _rest] = points
      assert is_integer(time)
      assert is_float(value)
    end

    test "selecting a window recomputes and re-pushes the chart", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{points: _initial})

      view |> element("#window-1m") |> render_click()

      assert has_element?(view, "#window-1m[class*='bg-base-100']")
      assert_push_event(view, "chart:data", %{points: points, mode: "value"})
      # Daily grid: one midnight per day of the month window.
      assert length(points) in 29..32
    end

    test "toggling profit mode pushes the profit series without changing the hero", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{mode: "value"})
      hero_before = view |> element("#portfolio-value") |> render()

      view |> element("#mode-profit") |> render_click()

      assert_push_event(view, "chart:data", %{points: points, mode: "profit"})
      assert points != []
      assert view |> element("#portfolio-value") |> render() == hero_before
    end

    test "switching the display currency re-renders the hero and cards", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      seed_fx_rates("USD", Date.add(Date.utc_today(), -40), Date.utc_today(), "1.25", "0")
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#currency-USD") |> render_click()

      assert view |> element("#portfolio-value") |> render() =~ "$"
      assert view |> element("#asset-#{bitcoin.id}") |> render() =~ "$"
      assert_push_event(view, "chart:data", %{points: _points})
    end

    test "asset cards render a sparkline colored by the window change", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      card = view |> element("#asset-#{bitcoin.id}") |> render()
      assert card =~ "polyline"
      assert card =~ "text-success"
      assert card =~ "BTC"
    end

    test "an asset without stored prices shows the pending state instead of zeros", %{
      conn: conn,
      portfolio: portfolio
    } do
      pending = stock_asset_fixture(%{name: "Newly Added", symbol: "NEW"})

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: pending.id,
        executed_at: DateTime.new!(Date.add(Date.utc_today(), -3), ~T[10:00:00], "Etc/UTC"),
        quantity: "1",
        price_per_unit: "10",
        currency: "USD"
      })

      {:ok, view, _html} = live(conn, ~p"/")

      card = view |> element("#asset-#{pending.id}") |> render()
      assert card =~ "No price data yet"
      refute card =~ "polyline"
    end

    test "a price update broadcast refreshes the dashboard", %{conn: conn, bitcoin: bitcoin} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{points: _initial})

      :ok =
        MarketData.upsert_daily_prices(bitcoin.id, [
          %{date: Date.utc_today(), price: Decimal.new("500")}
        ])

      assert_push_event(view, "chart:data", %{points: _refreshed})
      assert view |> element("#portfolio-value") |> render() =~ "1,000.00"
    end

    test "tapping a card lists the asset's transactions with edit links", %{
      conn: conn,
      portfolio: portfolio,
      bitcoin: bitcoin
    } do
      [transaction] = Folio.Portfolios.list_transactions(portfolio.id)
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")

      assert has_element?(view, "#transaction-#{transaction.id}")
      assert view |> element("#asset-transactions") |> render() =~ "BUY"
    end

    test "asset page shows the chart and pushes asset-scoped series", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{points: _initial})

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")

      assert has_element?(view, "#asset-chart")
      assert has_element?(view, "#asset-window-1w[class*='bg-base-100']")
      assert has_element?(view, "#asset-mode-value[class*='bg-base-100']")
      assert has_element?(view, "#asset-currency-EUR[class*='bg-base-100']")

      assert_push_event(view, "chart:data", %{points: points, mode: "value"})
      assert points != []
    end

    test "selecting an asset window re-pushes the asset series", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{points: _initial})

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")
      assert_push_event(view, "chart:data", %{points: _asset_initial})

      view |> element("#asset-window-1m") |> render_click()

      assert has_element?(view, "#asset-window-1m[class*='bg-base-100']")
      assert_push_event(view, "chart:data", %{points: points, mode: "value"})
      assert points != []
    end

    test "toggling asset mode pushes the profit series", %{conn: conn, bitcoin: bitcoin} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{points: _initial})

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")
      assert_push_event(view, "chart:data", %{points: _asset_initial})

      view |> element("#asset-mode-profit") |> render_click()

      assert has_element?(view, "#asset-mode-profit[class*='bg-base-100']")
      assert_push_event(view, "chart:data", %{points: points, mode: "profit"})
      assert points != []
    end

    test "switching the asset chart currency re-pushes the converted series", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      seed_fx_rates("USD", Date.add(Date.utc_today(), -40), Date.utc_today(), "1.25", "0")
      {:ok, view, _html} = live(conn, ~p"/")
      assert_push_event(view, "chart:data", %{points: _initial})

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")
      assert_push_event(view, "chart:data", %{points: _asset_initial})

      view |> element("#asset-currency-USD") |> render_click()

      assert has_element?(view, "#asset-currency-USD[class*='bg-base-100']")
      assert_push_event(view, "chart:data", %{points: points, currency: "USD"})
      assert points != []
    end

    test "asset page shows position tiles comparing now to buy time", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")

      assert has_element?(view, "#asset-position")
      assert view |> element("#asset-position-value") |> render() =~ "at buy"
      assert view |> element("#asset-position-price") |> render() =~ "at buy"
      assert has_element?(view, "#asset-position-profit")
      assert has_element?(view, "#asset-position-return")

      assert has_element?(view, "h2", "My position")
      assert has_element?(view, "h2", "Transactions")
      assert view |> element("#asset-position-quantity") |> render() =~ "2 BTC"

      assert view |> element("#asset-position-quantity") |> render() =~
               "+2 last 12 months"
    end

    test "switching the asset currency recomputes the position tiles", %{
      conn: conn,
      bitcoin: bitcoin
    } do
      seed_fx_rates("USD", Date.add(Date.utc_today(), -40), Date.utc_today(), "1.25", "0")
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#asset-#{bitcoin.id}") |> render_click()
      assert_patch(view, ~p"/assets/#{bitcoin.id}")
      eur_value = view |> element("#asset-position-value") |> render()

      view |> element("#asset-currency-USD") |> render_click()

      usd_value = view |> element("#asset-position-value") |> render()
      refute usd_value == eur_value
    end
  end

  describe "asset chart visibility" do
    test "hides the chart for an unresolved asset even with stored prices", %{
      conn: conn,
      portfolio: portfolio
    } do
      today = Date.utc_today()
      unresolved = stock_asset_fixture(%{isin: nil, name: "Pending Co", ticker: "PEND"})
      seed_daily_prices(unresolved.id, Date.add(today, -10), today, "20", "1")

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: unresolved.id,
        executed_at: DateTime.new!(Date.add(today, -5), ~T[10:00:00], "Etc/UTC"),
        quantity: "1",
        price_per_unit: "20",
        currency: "USD"
      })

      {:ok, view, _html} = live(conn, ~p"/assets/#{unresolved.id}")

      assert has_element?(view, "#asset-unresolved")
      refute has_element?(view, "#asset-chart")
    end

    test "hides the chart when the asset has no stored price data", %{
      conn: conn,
      portfolio: portfolio
    } do
      today = Date.utc_today()
      pending = stock_asset_fixture(%{name: "Newly Added", ticker: "NEW"})

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: pending.id,
        executed_at: DateTime.new!(Date.add(today, -3), ~T[10:00:00], "Etc/UTC"),
        quantity: "1",
        price_per_unit: "10",
        currency: "USD"
      })

      {:ok, view, _html} = live(conn, ~p"/assets/#{pending.id}")

      refute has_element?(view, "#asset-unresolved")
      refute has_element?(view, "#asset-chart")
    end
  end

  describe "asset position tiles" do
    test "hidden once the position is fully sold", %{conn: conn, portfolio: portfolio} do
      today = Date.utc_today()
      bitcoin = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
      seed_daily_prices(bitcoin.id, Date.add(today, -10), today, "100", "1")

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: bitcoin.id,
        executed_at: DateTime.new!(Date.add(today, -8), ~T[10:00:00], "Etc/UTC"),
        quantity: "2",
        price_per_unit: "100"
      })

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: bitcoin.id,
        type: :sell,
        executed_at: DateTime.new!(Date.add(today, -1), ~T[10:00:00], "Etc/UTC"),
        quantity: "2",
        price_per_unit: "108"
      })

      {:ok, view, _html} = live(conn, ~p"/assets/#{bitcoin.id}")

      refute has_element?(view, "#asset-position")
      refute has_element?(view, "h2", "My position")
      assert has_element?(view, "h2", "Transactions")
    end
  end

  describe "without transactions" do
    test "renders the empty state without chart or change indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#empty-state")
      assert view |> element("#empty-state") |> render() =~ "Nothing here yet"
      refute has_element?(view, "#portfolio-chart")
      refute has_element?(view, "#portfolio-change")
      assert view |> element("#portfolio-value") |> render() =~ "€ 0.00"
      assert has_element?(view, "#fab-add")
    end
  end
end
