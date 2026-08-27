defmodule Folio.MarketData.CacheTest do
  # Not async: the cache is a single, globally named ETS table.
  use ExUnit.Case, async: false

  alias Folio.MarketData.Cache

  @ttls %{ok: :timer.minutes(10), error: :timer.seconds(60)}

  setup do
    Cache.clear()
    :ok
  end

  defp counting_fun(result) do
    test_pid = self()

    fn ->
      send(test_pid, :called)
      result
    end
  end

  test "a hit is served without re-invoking the function" do
    fun = counting_fun({:ok, [:hit]})

    assert Cache.fetch(:key, @ttls, fun) == {:ok, [:hit]}
    assert Cache.fetch(:key, @ttls, fun) == {:ok, [:hit]}

    assert_received :called
    refute_received :called
  end

  test "an expired entry is re-fetched" do
    assert Cache.fetch(:key, %{@ttls | ok: 1}, counting_fun({:ok, 1})) == {:ok, 1}
    Process.sleep(5)
    assert Cache.fetch(:key, @ttls, counting_fun({:ok, 2})) == {:ok, 2}
  end

  test "a rate-limit response is cached, so a throttled provider is not hammered" do
    fun = counting_fun({:error, :rate_limited})

    assert Cache.fetch(:key, @ttls, fun) == {:error, :rate_limited}
    assert Cache.fetch(:key, @ttls, fun) == {:error, :rate_limited}

    assert_received :called
    refute_received :called
  end

  test "the rate-limit entry uses the shorter error TTL" do
    fun = counting_fun({:error, :rate_limited})

    assert Cache.fetch(:key, %{ok: :timer.minutes(10), error: 1}, fun)
    Process.sleep(5)
    assert Cache.fetch(:key, @ttls, counting_fun({:ok, :recovered})) == {:ok, :recovered}
  end

  test "other errors are never cached, so a transient failure recovers at once" do
    assert Cache.fetch(:key, @ttls, counting_fun({:error, {:http_status, 500}})) ==
             {:error, {:http_status, 500}}

    assert Cache.fetch(:key, @ttls, counting_fun({:ok, :recovered})) == {:ok, :recovered}
  end

  test "a zero TTL bypasses the cache entirely" do
    ttls = %{ok: 0, error: 0}
    fun = counting_fun({:ok, 1})

    assert Cache.fetch(:key, ttls, fun) == {:ok, 1}
    assert Cache.fetch(:key, ttls, fun) == {:ok, 1}

    assert_received :called
    assert_received :called
    assert :ets.info(:folio_market_data_cache, :size) == 0
  end

  test "clear/0 drops every entry" do
    Cache.fetch(:key, @ttls, counting_fun({:ok, 1}))
    assert :ets.info(:folio_market_data_cache, :size) == 1

    assert Cache.clear() == :ok
    assert :ets.info(:folio_market_data_cache, :size) == 0
  end
end
