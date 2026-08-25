defmodule Folio.Clients.Frankfurter do
  @moduledoc """
  Frankfurter client (keyless ECB reference rates, EUR base). Business days
  only - weekend gaps are expected and handled by at-or-before lookups.
  """

  @behaviour Folio.Clients.FxClient

  import Folio.Clients.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  @base_url "https://api.frankfurter.dev/v1"

  @impl true
  def latest_rates(currencies) do
    params = [base: "EUR", symbols: Enum.join(currencies, ",")]

    with {:ok, body} <- [url: @base_url <> "/latest", params: params] |> request() |> handle() do
      {:ok, %{date: Date.from_iso8601!(body["date"]), rates: decimal_rates(body["rates"])}}
    end
  end

  @impl true
  def historical_rates(currencies, from, to) do
    params = [base: "EUR", symbols: Enum.join(currencies, ",")]
    url = @base_url <> "/#{Date.to_iso8601(from)}..#{Date.to_iso8601(to)}"

    with {:ok, body} <- [url: url, params: params] |> request() |> handle() do
      entries =
        body
        |> Map.get("rates", %{})
        |> Enum.map(fn {date_string, rates} ->
          %{date: Date.from_iso8601!(date_string), rates: decimal_rates(rates)}
        end)
        |> Enum.sort_by(& &1.date, Date)

      {:ok, entries}
    end
  end

  defp decimal_rates(rates) do
    Map.new(rates || %{}, fn {currency, rate} -> {currency, to_decimal(rate)} end)
  end

  defp request(opts), do: opts |> base() |> Req.request()
end
