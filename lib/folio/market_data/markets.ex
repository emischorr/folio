defmodule Folio.MarketData.Markets do
  @moduledoc """
  Hardcoded registry of supported trading venues, keyed by ISO 10383 MIC.

  Assets reference a venue only by MIC; everything else about the venue
  (display name, default currency, timezone, trading hours) lives here.
  Adding a market is a code change with a test, not a lookup.
  """

  @type market :: %{
          mic: String.t(),
          name: String.t(),
          country: String.t(),
          currency: String.t(),
          timezone: String.t(),
          trading_hours: {Time.t(), Time.t()}
        }

  # Trading hours are local exchange time. The regional floors (XBER etc.) list
  # their electronic trading windows; the point is refresh gating, not tick-level
  # session accuracy.
  @markets [
    %{
      mic: "XETR",
      name: "Xetra",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[09:00:00], ~T[17:30:00]}
    },
    %{
      mic: "XFRA",
      name: "Börse Frankfurt",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[22:00:00]}
    },
    %{
      mic: "XGAT",
      name: "Tradegate",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[22:00:00]}
    },
    %{
      mic: "XMUN",
      name: "gettex",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[22:00:00]}
    },
    %{
      mic: "XSTU",
      name: "Börse Stuttgart",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[22:00:00]}
    },
    %{
      mic: "XBER",
      name: "Börse Berlin",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[20:00:00]}
    },
    %{
      mic: "XDUS",
      name: "Börse Düsseldorf",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[20:00:00]}
    },
    %{
      mic: "XHAM",
      name: "Börse Hamburg",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[20:00:00]}
    },
    %{
      mic: "XHAN",
      name: "Börse Hannover",
      country: "DE",
      currency: "EUR",
      timezone: "Europe/Berlin",
      trading_hours: {~T[08:00:00], ~T[20:00:00]}
    },
    %{
      mic: "XLON",
      name: "London Stock Exchange",
      country: "GB",
      currency: "GBP",
      timezone: "Europe/London",
      trading_hours: {~T[08:00:00], ~T[16:30:00]}
    },
    %{
      mic: "XAMS",
      name: "Euronext Amsterdam",
      country: "NL",
      currency: "EUR",
      timezone: "Europe/Amsterdam",
      trading_hours: {~T[09:00:00], ~T[17:30:00]}
    },
    %{
      mic: "XPAR",
      name: "Euronext Paris",
      country: "FR",
      currency: "EUR",
      timezone: "Europe/Paris",
      trading_hours: {~T[09:00:00], ~T[17:30:00]}
    },
    %{
      mic: "XMIL",
      name: "Borsa Italiana",
      country: "IT",
      currency: "EUR",
      timezone: "Europe/Rome",
      trading_hours: {~T[09:00:00], ~T[17:30:00]}
    },
    %{
      mic: "XSWX",
      name: "SIX Swiss Exchange",
      country: "CH",
      currency: "CHF",
      timezone: "Europe/Zurich",
      trading_hours: {~T[09:00:00], ~T[17:30:00]}
    },
    %{
      mic: "XWBO",
      name: "Wiener Börse",
      country: "AT",
      currency: "EUR",
      timezone: "Europe/Vienna",
      trading_hours: {~T[09:00:00], ~T[17:30:00]}
    },
    %{
      mic: "XNAS",
      name: "Nasdaq",
      country: "US",
      currency: "USD",
      timezone: "America/New_York",
      trading_hours: {~T[09:30:00], ~T[16:00:00]}
    },
    %{
      mic: "XNYS",
      name: "New York Stock Exchange",
      country: "US",
      currency: "USD",
      timezone: "America/New_York",
      trading_hours: {~T[09:30:00], ~T[16:00:00]}
    },
    %{
      mic: "ARCX",
      name: "NYSE Arca",
      country: "US",
      currency: "USD",
      timezone: "America/New_York",
      trading_hours: {~T[09:30:00], ~T[16:00:00]}
    },
    %{
      mic: "XTSE",
      name: "Toronto Stock Exchange",
      country: "CA",
      currency: "CAD",
      timezone: "America/Toronto",
      trading_hours: {~T[09:30:00], ~T[16:00:00]}
    },
    %{
      mic: "XHKG",
      name: "Hong Kong Stock Exchange",
      country: "HK",
      currency: "HKD",
      timezone: "Asia/Hong_Kong",
      trading_hours: {~T[09:30:00], ~T[16:00:00]}
    }
  ]

  @by_mic Map.new(@markets, &{&1.mic, &1})

  @german_retail_mics ~w(XETR XFRA XGAT XMUN XSTU XBER XDUS XHAM XHAN)

  # A refresh tick shortly before the open or after the close should still count
  # as in-session so the opening and closing prices are captured.
  @padding_seconds 15 * 60

  @doc "All supported markets, in registry order."
  @spec all() :: [market()]
  def all, do: @markets

  @doc "The market for a MIC, or nil when unsupported."
  @spec get(String.t()) :: market() | nil
  def get(mic), do: Map.get(@by_mic, mic)

  @spec mics() :: [String.t()]
  def mics, do: Enum.map(@markets, & &1.mic)

  @doc "Display name for a MIC; falls back to the MIC itself for unknown venues."
  @spec name(String.t() | nil) :: String.t() | nil
  def name(nil), do: nil

  def name(mic) do
    case get(mic) do
      %{name: name} -> name
      nil -> mic
    end
  end

  @doc "Default quote currency of a venue."
  @spec currency(String.t() | nil) :: String.t() | nil
  def currency(nil), do: nil

  def currency(mic) do
    case get(mic) do
      %{currency: currency} -> currency
      nil -> nil
    end
  end

  @doc """
  Whether the venue is in session at `at` (±15 min padding, Mon-Fri).

  Unknown MICs are treated as always open so a missing registry entry degrades
  to polling, never to silently stale prices. Public holidays are not modelled;
  a closed-day poll just fetches an unchanged price.
  """
  @spec open?(String.t() | nil, DateTime.t()) :: boolean()
  def open?(mic, %DateTime{} = at) do
    case get(mic) do
      nil -> true
      %{timezone: timezone, trading_hours: hours} -> open_in_zone?(at, timezone, hours)
    end
  end

  @doc "MICs a German retail investor trades on (used by source coverage checks)."
  @spec german_retail_mics() :: [String.t()]
  def german_retail_mics, do: @german_retail_mics

  defp open_in_zone?(at, timezone, {open, close}) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, local} -> weekday?(local) and within_hours?(DateTime.to_time(local), open, close)
      {:error, _reason} -> true
    end
  end

  defp weekday?(local), do: Date.day_of_week(DateTime.to_date(local)) in 1..5

  defp within_hours?(time, open, close) do
    Time.compare(time, Time.add(open, -@padding_seconds)) != :lt and
      Time.compare(time, Time.add(close, @padding_seconds)) != :gt
  end
end
