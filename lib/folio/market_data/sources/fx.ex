defmodule Folio.MarketData.Sources.FX do
  @moduledoc """
  Behaviour for EUR-pivot foreign exchange rates.

  One implementation (Frankfurter) today; the behaviour exists so the FX
  source is swappable like every other source.
  """

  @doc "Latest available EUR-base rates for the given currencies."
  @callback latest_rates([String.t()]) ::
              {:ok, %{date: Date.t(), rates: %{String.t() => Decimal.t()}}} | {:error, term()}

  @doc "EUR-base rates per business day within `[from, to]`, ascending."
  @callback historical_rates([String.t()], from :: Date.t(), to :: Date.t()) ::
              {:ok, [%{date: Date.t(), rates: %{String.t() => Decimal.t()}}]} | {:error, term()}
end
