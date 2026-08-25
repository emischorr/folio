defmodule Folio.AssetsFixtures do
  @moduledoc "Test fixtures for assets. Direct inserts - no backfill jobs are enqueued."

  alias Folio.Assets.Asset
  alias Folio.Repo

  @doc "Inserts a crypto asset (CoinGecko-sourced, EUR-quoted)."
  @spec crypto_asset_fixture(map()) :: Asset.t()
  def crypto_asset_fixture(attrs \\ %{}) do
    insert(
      %{
        symbol: "BTC",
        name: "Bitcoin",
        kind: :crypto,
        quote_currency: "EUR",
        price_source: :coingecko,
        source_id: "bitcoin-#{System.unique_integer([:positive])}"
      },
      attrs
    )
  end

  @doc "Inserts a US stock asset (Yahoo-sourced, USD-quoted)."
  @spec stock_asset_fixture(map()) :: Asset.t()
  def stock_asset_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    insert(
      %{
        symbol: "NVDA",
        name: "NVIDIA Corporation",
        kind: :stock,
        exchange: "NasdaqGS",
        quote_currency: "USD",
        price_source: :yahoo,
        source_id: "NVDA-#{unique}"
      },
      attrs
    )
  end

  @doc "Inserts a EUR-quoted ETF asset (Yahoo-sourced)."
  @spec etf_asset_fixture(map()) :: Asset.t()
  def etf_asset_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    insert(
      %{
        symbol: "EUNL.DE",
        name: "iShares Core MSCI World",
        kind: :etf,
        exchange: "XETRA",
        quote_currency: "EUR",
        price_source: :yahoo,
        source_id: "EUNL.DE-#{unique}"
      },
      attrs
    )
  end

  defp insert(defaults, attrs) do
    Repo.insert!(struct!(Asset, Map.merge(defaults, attrs)))
  end
end
