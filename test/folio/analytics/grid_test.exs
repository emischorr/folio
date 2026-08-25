defmodule Folio.Analytics.GridTest do
  use ExUnit.Case, async: true

  alias Folio.Analytics.Grid

  @now ~U[2026-08-25 10:07:33Z]

  test "1d: 15-minute points floored to the step, ending exactly at now" do
    grid = Grid.timestamps(:"1d", @now, nil)

    assert List.first(grid) == ~U[2026-08-24 10:00:00Z]
    assert List.last(grid) == @now
    assert length(grid) == 98
    assert Enum.at(grid, 1) == ~U[2026-08-24 10:15:00Z]
  end

  test "1w: hourly points ending exactly at now" do
    grid = Grid.timestamps(:"1w", @now, nil)

    assert List.first(grid) == ~U[2026-08-18 10:00:00Z]
    assert List.last(grid) == @now
    assert length(grid) == 170
  end

  test "daily windows are midnights through today" do
    grid = Grid.timestamps(:"1m", @now, nil)
    assert List.first(grid) == ~U[2026-07-26 00:00:00Z]
    assert List.last(grid) == ~U[2026-08-25 00:00:00Z]
    assert length(grid) == 31

    assert Grid.timestamps(:ytd, @now, nil) |> List.first() == ~U[2026-01-01 00:00:00Z]
    assert Grid.timestamps(:"1y", @now, nil) |> length() == 366
  end

  test "max spans from the earliest transaction date; empty without one" do
    assert Grid.timestamps(:max, @now, nil) == []

    grid = Grid.timestamps(:max, @now, ~D[2026-08-20])
    assert List.first(grid) == ~U[2026-08-20 00:00:00Z]
    assert length(grid) == 6
  end

  test "window_start/3 is the first grid point" do
    assert Grid.window_start(:"1m", @now, nil) == ~U[2026-07-26 00:00:00Z]
    assert Grid.window_start(:max, @now, nil) == nil
  end
end
