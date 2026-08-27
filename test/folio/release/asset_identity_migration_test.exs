defmodule Folio.Release.AssetIdentityMigrationTest do
  use ExUnit.Case, async: true

  alias Folio.Release.AssetIdentityMigration

  defp security(source_id, exchange \\ nil) do
    %{kind: "etf", price_source: "yahoo", source_id: source_id, exchange: exchange}
  end

  test "crypto rows derive nothing" do
    assert AssetIdentityMigration.derive(%{
             kind: "crypto",
             price_source: "coingecko",
             source_id: "bitcoin",
             exchange: nil
           }) == :crypto
  end

  test "every Yahoo venue suffix maps to its MIC" do
    expected = %{
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

    for {suffix, mic} <- expected do
      assert AssetIdentityMigration.derive(security("EUNL.#{suffix}")) ==
               %{ticker: "EUNL", mic: mic}
    end
  end

  test "an unknown suffix keeps the ticker but stays unresolved" do
    assert AssetIdentityMigration.derive(security("NVDC34.SA")) == %{ticker: "NVDC34", mic: nil}
  end

  test "suffix-less symbols disambiguate US venues via the old exchange text" do
    assert AssetIdentityMigration.derive(security("NVDA", "NasdaqGS")) ==
             %{ticker: "NVDA", mic: "XNAS"}

    assert AssetIdentityMigration.derive(security("BRK-B", "NYSE")) ==
             %{ticker: "BRK-B", mic: "XNYS"}

    assert AssetIdentityMigration.derive(security("SPY", "NYSEArca")) ==
             %{ticker: "SPY", mic: "ARCX"}
  end

  test "a suffix-less symbol without a recognizable exchange stays unresolved" do
    assert AssetIdentityMigration.derive(security("NVDX", "BATS")) == %{ticker: "NVDX", mic: nil}
    assert AssetIdentityMigration.derive(security("NVDX")) == %{ticker: "NVDX", mic: nil}
  end

  test "unparseable rows derive nothing at all" do
    assert AssetIdentityMigration.derive(security("A.B.C")) == %{ticker: nil, mic: nil}

    assert AssetIdentityMigration.derive(%{
             kind: "stock",
             price_source: "yahoo",
             source_id: nil,
             exchange: nil
           }) == %{ticker: nil, mic: nil}
  end
end
