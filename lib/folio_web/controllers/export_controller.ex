defmodule FolioWeb.ExportController do
  @moduledoc """
  Downloads transactions as CSV. A plain controller, not a `DashboardLive`
  live_action, since a LiveView process can't stream a file response with a
  `Content-Disposition` header on its own.
  """

  use FolioWeb, :controller

  alias Folio.ImportExport
  alias Folio.Portfolios

  @doc "Downloads all of the current portfolio's transactions."
  @spec all(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def all(conn, _params) do
    portfolio = current_portfolio(conn)
    download(conn, ImportExport.export_csv(portfolio.id), "transactions.csv")
  end

  @doc "Downloads one asset's transactions in the current portfolio."
  @spec asset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def asset(conn, %{"asset_id" => asset_id}) do
    portfolio = current_portfolio(conn)
    csv = ImportExport.export_csv(portfolio.id, String.to_integer(asset_id))
    download(conn, csv, "transactions-#{asset_id}.csv")
  end

  defp current_portfolio(conn) do
    %{user: user} = conn.assigns.current_scope
    Portfolios.default_portfolio_for(user.id)
  end

  defp download(conn, csv, filename) do
    send_download(conn, {:binary, IO.iodata_to_binary(csv)}, filename: filename)
  end
end
