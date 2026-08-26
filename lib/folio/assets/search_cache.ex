defmodule Folio.Assets.SearchCache do
  @moduledoc """
  Short-lived cache for asset-resolution lookups. Yahoo's search endpoint is
  rate-limited per IP and answers 429 long before you expect it, so repeated
  resolutions must not each spend fresh quota.

  Deliberately not part of the clients: `quote_meta/1` is also the intraday
  price path (`RefreshEquityPrices`), and caching there would persist stale
  ticks. Resolution only reads the currency and exchange, and discards the
  price.

  Rate-limit responses are cached under their own, shorter TTL - while a
  provider is refusing requests there is nothing to gain from making more of
  them. Other errors are never cached, so a transient failure recovers on the
  next keystroke.
  """

  use GenServer

  @table :folio_search_cache
  @sweep_interval :timer.minutes(5)

  @typedoc "Milliseconds to keep a successful result and a rate-limit response."
  @type ttls :: %{ok: non_neg_integer(), error: non_neg_integer()}

  @doc "Starts the cache owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns the cached value for `key`, or evaluates `fun` and caches it
  according to `ttls`. An `:ok` TTL of zero bypasses the cache entirely.
  """
  @spec fetch(term(), ttls(), (-> value)) :: value when value: term()
  def fetch(_key, %{ok: 0}, fun), do: fun.()

  def fetch(key, ttls, fun) do
    case lookup(key) do
      {:hit, value} ->
        value

      :miss ->
        value = fun.()
        store(key, value, ttl_for(value, ttls))
        value
    end
  end

  @doc "Drops every entry."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, schedule_sweep()}
  end

  @impl true
  def handle_info(:sweep, _state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    {:noreply, schedule_sweep()}
  end

  defp ttl_for({:error, :rate_limited}, %{error: error_ttl}), do: error_ttl
  defp ttl_for({:error, _reason}, _ttls), do: 0
  defp ttl_for(_value, %{ok: ok_ttl}), do: ok_ttl

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] -> if expires_at > now(), do: {:hit, value}, else: :miss
      _miss -> :miss
    end
  rescue
    # The owner is not running; degrade to no caching rather than crash search.
    ArgumentError -> :miss
  end

  defp store(_key, _value, 0), do: :ok

  defp store(key, value, ttl_ms) do
    :ets.insert(@table, {key, value, now() + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp now, do: System.monotonic_time(:millisecond)
end
