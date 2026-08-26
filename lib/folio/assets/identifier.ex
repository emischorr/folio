defmodule Folio.Assets.Identifier do
  @moduledoc """
  Recognizes the security identifiers a user may type into asset search:
  ISIN (12 chars, mod-10 check digit) and WKN (6 alphanumerics). The
  checksum is what keeps six-character tickers out of the identifier
  lookup path, so it is validated rather than pattern-matched alone.
  """

  @isin_format ~r/^[A-Z]{2}[A-Z0-9]{9}[0-9]$/
  # A WKN always carries at least one digit, which is what keeps six-letter
  # words like "NVIDIA" or "GOOGLE" out of the identifier lookup path.
  @wkn_format ~r/^(?=[A-Z0-9]{6}$)[A-Z]*[0-9][A-Z0-9]*$/

  @doc "Upcases and strips the spaces and dashes people paste along with an identifier."
  @spec normalize(String.t()) :: String.t()
  def normalize(query) do
    query
    |> String.upcase()
    |> String.replace(~r/[\s-]/, "")
  end

  @doc "True when the value is a well-formed ISIN with a valid check digit."
  @spec isin?(String.t()) :: boolean()
  def isin?(value) do
    Regex.match?(@isin_format, value) and luhn_valid?(expand(value))
  end

  @doc "True when the value looks like a WKN (and is not an ISIN)."
  @spec wkn?(String.t()) :: boolean()
  def wkn?(value) do
    Regex.match?(@wkn_format, value) and not isin?(value)
  end

  @doc """
  Classifies a raw search query. `:wkn` is advisory - a six-character
  query is just as likely to be a ticker, so callers should search text
  as well.
  """
  @spec classify(String.t()) :: {:isin, String.t()} | {:wkn, String.t()} | :text
  def classify(query) do
    normalized = normalize(query)

    cond do
      isin?(normalized) -> {:isin, normalized}
      wkn?(normalized) -> {:wkn, normalized}
      true -> :text
    end
  end

  # Letters expand to their two-digit alphabet position (A=10 .. Z=35).
  defp expand(value) do
    for <<char <- value>>, into: "" do
      cond do
        char in ?0..?9 -> <<char>>
        char in ?A..?Z -> Integer.to_string(char - ?A + 10)
      end
    end
  end

  defp luhn_valid?(digits) do
    sum =
      digits
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, index}, acc ->
        digit = char - ?0
        acc + if rem(index, 2) == 1, do: double(digit), else: digit
      end)

    rem(sum, 10) == 0
  end

  defp double(digit) when digit < 5, do: digit * 2
  defp double(digit), do: digit * 2 - 9
end
