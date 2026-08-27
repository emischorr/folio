defmodule Folio.MarketData.SourceStats do
  @moduledoc """
  Counts every source-chain outcome so a silently broken source becomes visible.

  The chain emits `[:folio, :market_data, :source]` telemetry with
  `%{source:, concern:, outcome:}` metadata; this process attaches a handler
  that bumps a counter per `{source, concern, outcome}` in a public ETS table.
  `snapshot/0` returns the counters, e.g. from iex while debugging.
  """

  use GenServer

  @event [:folio, :market_data, :source]

  @doc "Options: `:name` and `:table` (defaults for the app instance)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current counters as `%{{source, concern, outcome} => count}`."
  @spec snapshot(atom()) :: %{{atom(), atom(), atom()} => pos_integer()}
  def snapshot(table \\ __MODULE__) do
    table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, __MODULE__)
    :ets.new(table, [:set, :public, :named_table, write_concurrency: true])

    :telemetry.attach(
      {__MODULE__, table},
      @event,
      &__MODULE__.handle_event/4,
      %{table: table}
    )

    {:ok, %{table: table}}
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :telemetry.detach({__MODULE__, table})
  end

  @doc false
  def handle_event(
        @event,
        _measurements,
        %{source: source, concern: concern, outcome: outcome},
        %{table: table}
      ) do
    :ets.update_counter(table, {source, concern, outcome}, 1, {{source, concern, outcome}, 0})
  rescue
    ArgumentError -> :ok
  end
end
