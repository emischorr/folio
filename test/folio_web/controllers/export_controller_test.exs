defmodule FolioWeb.ExportControllerTest do
  use FolioWeb.ConnCase, async: true

  import Folio.AssetsFixtures
  import Folio.PortfoliosFixtures

  setup :bootstrap_default_user

  describe "GET /export/transactions" do
    test "downloads all transactions as CSV", %{conn: conn, portfolio: portfolio} do
      asset = crypto_asset_fixture()
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})

      conn = get(conn, ~p"/export/transactions")

      assert response_content_type(conn, :csv) =~ "text/csv"
      assert [attachment] = get_resp_header(conn, "content-disposition")
      assert attachment =~ "transactions.csv"
      assert response(conn, 200) =~ "quantity"
    end
  end

  describe "GET /export/transactions/:asset_id" do
    test "downloads only that asset's transactions as CSV", %{conn: conn, portfolio: portfolio} do
      bitcoin = crypto_asset_fixture()
      stock = stock_asset_fixture()

      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: bitcoin.id})
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: stock.id, currency: "USD"})

      conn = get(conn, ~p"/export/transactions/#{bitcoin.id}")

      body = response(conn, 200)
      assert body =~ bitcoin.symbol
      refute body =~ stock.isin
    end
  end
end
