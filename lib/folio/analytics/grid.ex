defmodule Folio.Analytics.Grid do
  @moduledoc """
  Sampling grids per time window, all UTC. Intraday windows (`1d`, `1w`) step
  in 15-minute / hourly points floored to the step and always end exactly at
  `now`. Daily windows are midnights; a point at midnight of day D samples
  D's close once it exists ("value on D uses D's close"), otherwise the
  latest earlier close.
  """

  @type window :: :"1d" | :"1w" | :"1m" | :ytd | :"1y" | :max

  @windows [:"1d", :"1w", :"1m", :ytd, :"1y", :max]

  @doc "All supported windows."
  @spec windows() :: [window()]
  def windows, do: @windows

  @doc """
  Grid timestamps for the window, oldest first. `earliest` (the first
  transaction date) bounds `:max`; a nil `earliest` makes `:max` empty.
  """
  @spec timestamps(window(), DateTime.t(), Date.t() | nil) :: [DateTime.t()]
  def timestamps(:"1d", now, _earliest), do: stepped(DateTime.add(now, -1, :day), now, 15 * 60)
  def timestamps(:"1w", now, _earliest), do: stepped(DateTime.add(now, -7, :day), now, 60 * 60)
  def timestamps(:"1m", now, _earliest), do: daily(Date.add(DateTime.to_date(now), -30), now)
  def timestamps(:ytd, now, _earliest), do: daily(Date.new!(now.year, 1, 1), now)
  def timestamps(:"1y", now, _earliest), do: daily(Date.add(DateTime.to_date(now), -365), now)
  def timestamps(:max, _now, nil), do: []
  def timestamps(:max, now, earliest), do: daily(earliest, now)

  @doc "The window's opening timestamp (first grid point), or nil when empty."
  @spec window_start(window(), DateTime.t(), Date.t() | nil) :: DateTime.t() | nil
  def window_start(window, now, earliest) do
    window |> timestamps(now, earliest) |> List.first()
  end

  defp stepped(start, now, step_seconds) do
    first = floor_to_step(start, step_seconds)

    points =
      first
      |> Stream.iterate(&DateTime.add(&1, step_seconds, :second))
      |> Enum.take_while(&(DateTime.compare(&1, now) == :lt))

    points ++ [now]
  end

  defp floor_to_step(datetime, step_seconds) do
    unix = DateTime.to_unix(datetime)
    DateTime.from_unix!(unix - rem(unix, step_seconds))
  end

  defp daily(from_date, now) do
    today = DateTime.to_date(now)

    if Date.compare(from_date, today) == :gt do
      []
    else
      for date <- Date.range(from_date, today) do
        DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      end
    end
  end
end
