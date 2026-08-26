defmodule Folio.Assets.IdentifierTest do
  use ExUnit.Case, async: true

  alias Folio.Assets.Identifier

  describe "isin?/1" do
    test "accepts real ISINs across issuing countries" do
      for isin <- ~w(DE000EWG2LD7 IE00B3WJKG14 JE00BQRFDY49 IE00B44Z5B48 US0378331005) do
        assert Identifier.isin?(isin), "expected #{isin} to be a valid ISIN"
      end
    end

    test "rejects a wrong check digit" do
      refute Identifier.isin?("IE00B44Z5B49")
    end

    test "rejects malformed values" do
      refute Identifier.isin?("IE00B44Z5B4")
      refute Identifier.isin?("1E00B44Z5B48")
      refute Identifier.isin?("IE00B44Z5B4X")
    end
  end

  describe "wkn?/1" do
    test "accepts six-character identifiers" do
      assert Identifier.wkn?("EWG2LD")
      assert Identifier.wkn?("A142N1")
      assert Identifier.wkn?("716460")
    end

    test "rejects ISINs and anything that is not six characters" do
      refute Identifier.wkn?("DE000EWG2LD7")
      refute Identifier.wkn?("QDVE")
      refute Identifier.wkn?("EWG2LD7")
      # Six-letter words are far more likely to be a name than a WKN.
      refute Identifier.wkn?("NVIDIA")
    end
  end

  describe "classify/1" do
    test "normalizes before classifying" do
      assert Identifier.classify("de000ewg2ld7") == {:isin, "DE000EWG2LD7"}
      assert Identifier.classify("DE00 0EWG-2LD7") == {:isin, "DE000EWG2LD7"}
      assert Identifier.classify("ewg2ld") == {:wkn, "EWG2LD"}
    end

    test "falls back to text for names and tickers" do
      assert Identifier.classify("EUWAX Gold II") == :text
      assert Identifier.classify("QDVE.DE") == :text
      assert Identifier.classify("nvidia") == :text
      assert Identifier.classify("IE00B44Z5B49") == :text
    end
  end
end
