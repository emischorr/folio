defmodule Folio.AssetsFixtures do
  @moduledoc "Test fixtures for assets. Direct inserts - no backfill jobs are enqueued."

  alias Folio.Assets.Asset
  alias Folio.Repo

  @doc "Inserts a crypto asset (EUR-quoted)."
  @spec crypto_asset_fixture(map()) :: Asset.t()
  def crypto_asset_fixture(attrs \\ %{}) do
    insert(
      %{
        symbol: "BT#{System.unique_integer([:positive])}",
        name: "Bitcoin",
        kind: :crypto,
        quote_currency: "EUR"
      },
      attrs
    )
  end

  @doc "Inserts a US stock asset (Nasdaq, USD-quoted)."
  @spec stock_asset_fixture(map()) :: Asset.t()
  def stock_asset_fixture(attrs \\ %{}) do
    insert(
      %{
        ticker: "NVDA",
        name: "NVIDIA Corporation",
        kind: :stock,
        mic: "XNAS",
        isin: unique_isin(),
        quote_currency: "USD"
      },
      attrs
    )
  end

  @doc "Inserts a EUR-quoted ETF asset (Xetra)."
  @spec etf_asset_fixture(map()) :: Asset.t()
  def etf_asset_fixture(attrs \\ %{}) do
    insert(
      %{
        ticker: "EUNL",
        name: "iShares Core MSCI World",
        kind: :etf,
        mic: "XETR",
        isin: unique_isin(),
        quote_currency: "EUR"
      },
      attrs
    )
  end

  @doc "A syntactically valid, checksummed, unique ISIN."
  @spec unique_isin() :: String.t()
  def unique_isin do
    body =
      "US#{System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(9, "0") |> String.slice(-9..-1)}"

    body <> isin_check_digit(body)
  end

  defp isin_check_digit(body) do
    digits =
      body
      |> String.graphemes()
      |> Enum.flat_map(fn char ->
        case Integer.parse(char) do
          {digit, ""} -> [digit]
          :error -> char |> letter_value() |> Integer.digits()
        end
      end)

    sum =
      digits
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn
        {digit, index} when rem(index, 2) == 0 -> digit * 2
        {digit, _index} -> digit
      end)
      |> Enum.flat_map(&Integer.digits/1)
      |> Enum.sum()

    Integer.to_string(rem(10 - rem(sum, 10), 10))
  end

  defp letter_value(<<char>>), do: char - ?A + 10

  defp insert(defaults, attrs) do
    Repo.insert!(struct!(Asset, Map.merge(defaults, attrs)))
  end
end
