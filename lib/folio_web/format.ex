defmodule FolioWeb.Format do
  @moduledoc """
  Decimal-based display formatting for money, percentages, and quantities.
  Takes plain Decimals and currency-code strings only; nothing here touches
  floats or domain structs. Grouping follows the en convention ("24,318.52").
  """

  @doc ~S"""
  Money with symbol prefix: `money(Decimal.new("24318.52"), "EUR")` returns
  "€ 24,318.52". Negative amounts get a leading minus sign.
  """
  @spec money(Decimal.t(), String.t()) :: String.t()
  def money(%Decimal{} = amount, currency) do
    sign = if Decimal.negative?(amount), do: "−", else: ""
    sign <> currency_symbol(currency) <> " " <> grouped(amount)
  end

  @doc "Money of the absolute value (sign carried by arrow/color in the UI)."
  @spec money_abs(Decimal.t(), String.t()) :: String.t()
  def money_abs(%Decimal{} = amount, currency), do: money(Decimal.abs(amount), currency)

  @doc ~S{Signed percentage with one decimal: percent(pct) returns "+2.4 %". Nil passes through.}
  @spec percent(Decimal.t() | nil) :: String.t() | nil
  def percent(nil), do: nil

  def percent(%Decimal{} = pct) do
    rounded = Decimal.round(pct, 1)
    sign = if Decimal.negative?(rounded), do: "−", else: "+"
    sign <> Decimal.to_string(Decimal.abs(rounded), :normal) <> " %"
  end

  @doc ~S{Quantity with up to 8 decimals, trailing zeros trimmed: "0.142", "15".}
  @spec quantity(Decimal.t()) :: String.t()
  def quantity(%Decimal{} = quantity) do
    quantity
    |> Decimal.round(8)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  @doc ~S{Currency symbol: "EUR" returns "€", "USD" returns "$", otherwise the code itself.}
  @spec currency_symbol(String.t()) :: String.t()
  def currency_symbol("EUR"), do: "€"
  def currency_symbol("USD"), do: "$"
  def currency_symbol(code), do: code

  defp grouped(amount) do
    [int, frac] =
      amount
      |> Decimal.abs()
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> String.split(".")

    group_thousands(int) <> "." <> frac
  end

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/\d{3}(?=\d)/, "\\0,")
    |> String.reverse()
  end
end
