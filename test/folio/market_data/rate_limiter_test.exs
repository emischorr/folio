defmodule Folio.MarketData.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Folio.MarketData.RateLimiter

  defp start_limiter(context, limits, clock) do
    name = Module.concat(__MODULE__, context.test)
    start_supervised!({RateLimiter, name: name, limits: limits, clock: clock})
    name
  end

  test "empties after capacity acquires and refuses the next", context do
    limiter = start_limiter(context, [stub_source: [capacity: 3, per_minute: 60]], fn -> 0 end)

    for _ <- 1..3, do: assert(RateLimiter.acquire(:stub_source, limiter) == :ok)
    assert RateLimiter.acquire(:stub_source, limiter) == {:error, :rate_limited}
  end

  test "refills with elapsed time up to capacity", context do
    clock = :atomics.new(1, [])

    limiter =
      start_limiter(context, [stub_source: [capacity: 2, per_minute: 60]], fn ->
        :atomics.get(clock, 1)
      end)

    for _ <- 1..2, do: assert(RateLimiter.acquire(:stub_source, limiter) == :ok)
    assert RateLimiter.acquire(:stub_source, limiter) == {:error, :rate_limited}

    # 60/min = one token per second
    :atomics.put(clock, 1, 1_000)
    assert RateLimiter.acquire(:stub_source, limiter) == :ok
    assert RateLimiter.acquire(:stub_source, limiter) == {:error, :rate_limited}

    # a long pause refills to capacity, not beyond
    :atomics.put(clock, 1, 3_600_000)
    for _ <- 1..2, do: assert(RateLimiter.acquire(:stub_source, limiter) == :ok)
    assert RateLimiter.acquire(:stub_source, limiter) == {:error, :rate_limited}
  end

  test "buckets are independent per source", context do
    limiter =
      start_limiter(
        context,
        [one: [capacity: 1, per_minute: 1], two: [capacity: 1, per_minute: 1]],
        fn -> 0 end
      )

    assert RateLimiter.acquire(:one, limiter) == :ok
    assert RateLimiter.acquire(:one, limiter) == {:error, :rate_limited}
    assert RateLimiter.acquire(:two, limiter) == :ok
  end

  test "a source without a configured budget is unlimited", context do
    limiter = start_limiter(context, [], fn -> 0 end)

    for _ <- 1..50, do: assert(RateLimiter.acquire(:unbudgeted, limiter) == :ok)
  end
end
