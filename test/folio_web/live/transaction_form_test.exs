defmodule FolioWeb.TransactionFormTest do
  use FolioWeb.ConnCase, async: false

  import Folio.ApiStubCase
  import Folio.AssetsFixtures
  import Folio.PortfoliosFixtures

  alias Folio.Assets
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.Portfolios

  setup :bootstrap_default_user

  defp stub_remote_search do
    Req.Test.stub(Folio.MarketData.Sources, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.coingecko.com", "/api/v3/search"} ->
          json_body(conn, ~s({"coins":[]}))

        {"query1.finance.yahoo.com", "/v1/finance/search"} ->
          json_fixture(conn, "yahoo_search.json")

        {"query1.finance.yahoo.com", "/v8/finance/chart/" <> _symbol} ->
          json_fixture(conn, "yahoo_chart_nvda.json")
      end
    end)
  end

  defp stub_isin_search do
    Req.Test.stub(Folio.MarketData.Sources, fn conn ->
      case conn.request_path do
        "/v3/mapping" -> json_fixture(conn, "openfigi_not_found.json")
        "/v1/finance/search" -> json_fixture(conn, "yahoo_search_isin.json")
      end
    end)
  end

  defp search_and_select_nvda(view) do
    view
    |> element("#asset-search-form")
    |> render_change(%{"query" => "nvidia"})

    render_async(view)
    view |> element("#candidate-0") |> render_click()
  end

  describe "asset autocomplete" do
    test "searching lists remote candidates with their metadata", %{conn: conn} do
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view
      |> element("#asset-search-form")
      |> render_change(%{"query" => "nvidia"})

      html = render_async(view)
      assert html =~ "NVIDIA Corporation"
      assert view |> element("#candidate-0") |> render() =~ "NVDA · Nasdaq · USD"
    end

    test "local matches surface without any remote call", %{conn: conn} do
      asset = stock_asset_fixture(%{name: "NVIDIA Corporation"})
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view
      |> element("#asset-search-form")
      |> render_change(%{"query" => "nvid"})

      render_async(view)
      view |> element("#candidate-0") |> render_click()

      assert view |> element("#selected-asset") |> render() =~ asset.ticker
    end

    test "selecting a candidate locks it in and clearing reopens the search", %{conn: conn} do
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      search_and_select_nvda(view)
      assert view |> element("#selected-asset") |> render() =~ "NVIDIA Corporation"
      refute has_element?(view, "#asset-search-form")

      view |> element("#clear-asset") |> render_click()
      assert has_element?(view, "#asset-search-form")
    end
  end

  describe "validation" do
    test "invalid input renders inline errors without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      html =
        view
        |> element("#transaction-form")
        |> render_change(%{"transaction" => %{"quantity" => "0", "price_per_unit" => "-1"}})

      assert html =~ "must be greater than 0"
      assert html =~ "must be greater than or equal to 0"
    end

    test "submitting without an asset shows an asset error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view
      |> element("#transaction-form")
      |> render_submit(%{"transaction" => %{"quantity" => "1", "price_per_unit" => "10"}})

      assert view |> element("#asset-error") |> render() =~ "Choose an asset"
      assert Portfolios.list_transactions(portfolio_id(view)) == []
    end
  end

  describe "ISIN" do
    test "an ISIN search shows the identifier on the candidates and locks it in", %{conn: conn} do
      stub_isin_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view |> element("#asset-search-form") |> render_change(%{"query" => "DE000EWG2LD7"})
      render_async(view)

      assert view |> element("#candidate-0") |> render() =~ "EUWAX Gold II"
      assert view |> element("#candidate-0-isin") |> render() =~ "DE000EWG2LD7"

      view |> element("#candidate-0") |> render_click()
      assert view |> element("#selected-asset-isin") |> render() =~ "DE000EWG2LD7"
      refute has_element?(view, "#asset-isin-form")
    end

    test "a name search offers an editable ISIN that validates the check digit", %{conn: conn} do
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")
      search_and_select_nvda(view)

      assert has_element?(view, "#asset-isin-form")
      refute has_element?(view, "#selected-asset-isin")

      view |> element("#asset-isin-form") |> render_change(%{"isin" => "IE00B44Z5B49"})
      assert view |> element("#isin-error") |> render() =~ "Not a valid ISIN"

      view |> element("#asset-isin-form") |> render_change(%{"isin" => "ie00 b44z-5b48"})
      refute has_element?(view, "#isin-error")
      assert view |> element("#selected-asset-isin") |> render() =~ "IE00B44Z5B48"
    end

    test "a typed ISIN is stored on an asset that already exists locally", %{conn: conn} do
      asset = stock_asset_fixture(%{name: "NVIDIA Corporation", isin: nil})
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view |> element("#asset-search-form") |> render_change(%{"query" => "nvid"})
      render_async(view)
      view |> element("#candidate-0") |> render_click()
      view |> element("#asset-isin-form") |> render_change(%{"isin" => "US67066G1040"})

      view
      |> element("#transaction-form")
      |> render_submit(%{
        "transaction" => %{
          "date" => "2026-08-20",
          "time" => "14:30",
          "quantity" => "5",
          "price_per_unit" => "183.74",
          "currency" => "USD"
        }
      })

      assert_patch(view, ~p"/")
      assert Assets.get_asset!(asset.id).isin == "US67066G1040"
    end
  end

  describe "provider health" do
    test "a rate-limited search says so instead of showing nothing", %{conn: conn} do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view |> element("#asset-search-form") |> render_change(%{"query" => "nvidia"})
      render_async(view)

      assert view |> element("#search-status") |> render() =~ "rate-limited"
      # The manual-entry escape hatch has to stay reachable.
      view |> element("#toggle-entry-mode") |> render_click()
      assert has_element?(view, "#manual-asset-fields")
    end

    test "any other provider failure reports search as unavailable", %{conn: conn} do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 500) end)
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view |> element("#asset-search-form") |> render_change(%{"query" => "nvidia"})
      render_async(view)

      assert view |> element("#search-status") |> render() =~ "unavailable"
    end

    test "a healthy search shows no status message", %{conn: conn} do
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view |> element("#asset-search-form") |> render_change(%{"query" => "nvidia"})
      render_async(view)

      refute has_element?(view, "#search-status")
    end
  end

  describe "saving" do
    test "a remote candidate creates the asset, enqueues backfill, and saves", %{
      conn: conn,
      portfolio: portfolio
    } do
      stub_remote_search()
      {:ok, view, _html} = live(conn, ~p"/transactions/new")
      search_and_select_nvda(view)

      # A text hit carries no ISIN; identity requires one, so the user types it.
      view |> element("#asset-isin-form") |> render_change(%{"isin" => "US67066G1040"})

      view
      |> element("#transaction-form")
      |> render_submit(%{
        "transaction" => %{
          "date" => "2026-08-20",
          "time" => "14:30",
          "quantity" => "5",
          "price_per_unit" => "183.74",
          "fee" => "1",
          "currency" => "USD"
        }
      })

      assert_patch(view, ~p"/")

      assert [asset] = Assets.search_local("NVDA")
      assert asset.quote_currency == "USD"
      assert asset.ticker == "NVDA"
      assert asset.mic == "XNAS"
      assert asset.isin == "US67066G1040"
      assert_enqueued(worker: BackfillAssetPrices, args: %{asset_id: asset.id})

      assert [transaction] = Portfolios.list_transactions(portfolio.id)
      assert transaction.asset_id == asset.id
      assert transaction.type == :buy
      assert transaction.executed_at == ~U[2026-08-20 14:30:00Z]
      assert Decimal.eq?(transaction.quantity, "5")
      assert transaction.currency == "USD"
    end

    test "manual entry creates a vendor-neutral asset when search is no help", %{
      conn: conn,
      portfolio: portfolio
    } do
      {:ok, view, _html} = live(conn, ~p"/transactions/new")

      view |> element("#toggle-entry-mode") |> render_click()
      assert has_element?(view, "#manual-asset-fields")

      view
      |> element("#transaction-form")
      |> render_submit(%{
        "manual" => %{
          "code" => "ACME",
          "name" => "Acme SE",
          "kind" => "stock",
          "mic" => "XETR",
          "quote_currency" => "EUR",
          "isin" => "de000ewg2ld7"
        },
        "transaction" => %{
          "date" => "2026-08-20",
          "time" => "09:00",
          "quantity" => "2",
          "price_per_unit" => "50"
        }
      })

      assert_patch(view, ~p"/")

      assert [asset] = Assets.search_local("ACME")
      assert asset.ticker == "ACME"
      assert asset.mic == "XETR"
      assert asset.isin == "DE000EWG2LD7"
      assert asset.kind == :stock
      assert [_transaction] = Portfolios.list_transactions(portfolio.id)
    end
  end

  describe "editing" do
    setup %{portfolio: portfolio} do
      asset = stock_asset_fixture(%{name: "NVIDIA Corporation", symbol: "NVDA"})

      transaction =
        transaction_fixture(%{
          portfolio_id: portfolio.id,
          asset_id: asset.id,
          executed_at: ~U[2026-06-01 14:30:00Z],
          quantity: "10",
          price_per_unit: "100",
          currency: "USD"
        })

      %{asset: asset, transaction: transaction}
    end

    test "the form is prefilled and saves changes", %{
      conn: conn,
      transaction: transaction,
      portfolio: portfolio
    } do
      {:ok, view, html} = live(conn, ~p"/transactions/#{transaction.id}/edit")

      assert html =~ "Edit transaction"
      assert view |> element("#selected-asset") |> render() =~ "NVIDIA Corporation"
      assert view |> element("#transaction-form") |> render() =~ "2026-06-01"

      view
      |> element("#transaction-form")
      |> render_submit(%{"transaction" => %{"quantity" => "3"}})

      assert_patch(view, ~p"/")
      assert [updated] = Portfolios.list_transactions(portfolio.id)
      assert Decimal.eq?(updated.quantity, "3")
    end

    test "delete removes the transaction and returns to the dashboard", %{
      conn: conn,
      transaction: transaction,
      portfolio: portfolio
    } do
      {:ok, view, _html} = live(conn, ~p"/transactions/#{transaction.id}/edit")

      view |> element("#delete-transaction") |> render_click()

      assert_patch(view, ~p"/")
      assert Portfolios.list_transactions(portfolio.id) == []
    end
  end

  defp portfolio_id(view) do
    :sys.get_state(view.pid).socket.assigns.portfolio_id
  end
end
