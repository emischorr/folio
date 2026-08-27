defmodule Folio.MarketData.RateLimiter do
  @moduledoc """
  Per-source token buckets for outbound market-data requests.

  `acquire/2` never blocks: an empty bucket answers `{:error, :rate_limited}`
  and the caller (the source chain) moves on to the next source. Budgets come
  from `config :folio, :rate_limits`; a source without an entry is unlimited,
  so registering a new source can never hard-fail on a missing budget.

  A single GenServer serializes all bucket accounting - the market-data queue
  runs two jobs at a time, so throughput is no concern here.
  """

  use GenServer

  @type limit :: [capacity: pos_integer(), per_minute: pos_integer()]

  @doc """
  Options: `:name` (default `#{inspect(__MODULE__)}`), `:limits` (defaults to
  the `:rate_limits` app config), `:clock` (ms clock fun, a test seam).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Take one token from the source's bucket, or report the bucket empty."
  @spec acquire(atom(), GenServer.server()) :: :ok | {:error, :rate_limited}
  def acquire(source_key, server \\ __MODULE__) do
    GenServer.call(server, {:acquire, source_key})
  end

  @impl true
  def init(opts) do
    limits =
      opts
      |> Keyword.get_lazy(:limits, fn -> Application.get_env(:folio, :rate_limits, []) end)
      |> Map.new(fn {key, limit} ->
        {key,
         %{
           capacity: Keyword.fetch!(limit, :capacity),
           per_minute: Keyword.fetch!(limit, :per_minute)
         }}
      end)

    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    {:ok, %{limits: limits, buckets: %{}, clock: clock}}
  end

  @impl true
  def handle_call({:acquire, source_key}, _from, %{limits: limits} = state) do
    case Map.fetch(limits, source_key) do
      :error -> {:reply, :ok, state}
      {:ok, limit} -> take_token(source_key, limit, state)
    end
  end

  defp take_token(source_key, limit, %{buckets: buckets, clock: clock} = state) do
    now = clock.()
    bucket = Map.get(buckets, source_key, %{tokens: limit.capacity * 1.0, last_ms: now})
    tokens = refill(bucket, limit, now)

    if tokens >= 1.0 do
      bucket = %{tokens: tokens - 1.0, last_ms: now}
      {:reply, :ok, put_in(state.buckets[source_key], bucket)}
    else
      bucket = %{tokens: tokens, last_ms: now}
      {:reply, {:error, :rate_limited}, put_in(state.buckets[source_key], bucket)}
    end
  end

  defp refill(%{tokens: tokens, last_ms: last_ms}, limit, now) do
    min(limit.capacity * 1.0, tokens + (now - last_ms) * limit.per_minute / 60_000)
  end
end
