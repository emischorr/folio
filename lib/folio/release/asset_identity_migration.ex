defmodule Folio.Release.AssetIdentityMigration do
  @moduledoc """
  Pure derivation logic for the vendor-neutral asset identity migration.

  Takes an asset row as stored before the migration (string values, straight
  from SQL) and derives the exchange ticker and MIC from the vendor fields
  that are about to be dropped. Yahoo symbols carry a venue suffix
  ("EUNL.DE"); suffix-less symbols are US listings disambiguated by the old
  free-text `exchange` column. Anything underivable keeps `nil` and the asset
  surfaces as unresolved in the UI, repairable by hand.

  Kept separate from the migration file so the table below is unit-testable.
  """

  @suffix_to_mic %{
    "DE" => "XETR",
    "F" => "XFRA",
    "SG" => "XSTU",
    "MU" => "XMUN",
    "BE" => "XBER",
    "DU" => "XDUS",
    "HM" => "XHAM",
    "HA" => "XHAN",
    "TG" => "XGAT",
    "L" => "XLON",
    "MI" => "XMIL",
    "AS" => "XAMS",
    "PA" => "XPAR",
    "SW" => "XSWX",
    "VI" => "XWBO",
    "TO" => "XTSE",
    "HK" => "XHKG"
  }

  @doc """
  Derives `%{ticker:, mic:}` for a pre-migration security row, or `:crypto`
  for crypto rows (which keep their symbol and derive nothing).
  """
  @spec derive(%{
          kind: String.t(),
          price_source: String.t(),
          source_id: String.t() | nil,
          exchange: String.t() | nil
        }) :: :crypto | %{ticker: String.t() | nil, mic: String.t() | nil}
  def derive(%{kind: "crypto"}), do: :crypto

  def derive(%{price_source: "yahoo", source_id: source_id, exchange: exchange})
      when is_binary(source_id) do
    case String.split(source_id, ".") do
      [ticker, suffix] -> %{ticker: ticker, mic: Map.get(@suffix_to_mic, suffix)}
      [ticker] -> %{ticker: ticker, mic: us_mic(exchange)}
      _multi_dot -> %{ticker: nil, mic: nil}
    end
  end

  def derive(_row), do: %{ticker: nil, mic: nil}

  defp us_mic(nil), do: nil

  defp us_mic(exchange) do
    downcased = String.downcase(exchange)

    cond do
      String.contains?(downcased, "nasdaq") -> "XNAS"
      String.contains?(downcased, "arca") -> "ARCX"
      String.contains?(downcased, "nyse") -> "XNYS"
      true -> nil
    end
  end
end
