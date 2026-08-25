defmodule Folio.Clients.FxClient do
  @moduledoc """
  Provider-agnostic daily FX rates, always EUR-based (1 EUR = rate x currency).
  The active implementation is `Application.get_env(:folio, :clients)[:fx]`.
  """

  @callback latest_rates(currencies :: [String.t()]) ::
              {:ok, %{date: Date.t(), rates: %{String.t() => Decimal.t()}}} | {:error, term()}

  @callback historical_rates(currencies :: [String.t()], from :: Date.t(), to :: Date.t()) ::
              {:ok, [%{date: Date.t(), rates: %{String.t() => Decimal.t()}}]} | {:error, term()}
end
