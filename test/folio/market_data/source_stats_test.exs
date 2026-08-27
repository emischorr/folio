defmodule Folio.MarketData.SourceStatsTest do
  use ExUnit.Case, async: true

  alias Folio.MarketData.SourceStats

  test "counts telemetry outcomes per source, concern and outcome", context do
    name = Module.concat(__MODULE__, context.test)
    start_supervised!({SourceStats, name: name, table: name})

    meta = %{source: :stub_source, concern: :quote, outcome: :ok}
    :telemetry.execute([:folio, :market_data, :source], %{count: 1}, meta)
    :telemetry.execute([:folio, :market_data, :source], %{count: 1}, meta)
    :telemetry.execute([:folio, :market_data, :source], %{count: 1}, %{meta | outcome: :failed})

    snapshot = SourceStats.snapshot(name)
    assert snapshot[{:stub_source, :quote, :ok}] == 2
    assert snapshot[{:stub_source, :quote, :failed}] == 1
  end

  test "snapshot of a missing table is empty" do
    assert SourceStats.snapshot(:no_such_table) == %{}
  end
end
