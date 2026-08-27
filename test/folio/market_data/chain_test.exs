defmodule Folio.MarketData.ChainTest.OkSource do
  @moduledoc false
  def supports?(_arg), do: true
  def answer, do: {:ok, :from_ok_source}
end

defmodule Folio.MarketData.ChainTest.SecondSource do
  @moduledoc false
  def supports?(_arg), do: true
  def answer, do: {:ok, :from_second_source}
end

defmodule Folio.MarketData.ChainTest.FailingSource do
  @moduledoc false
  def supports?(_arg), do: true
  def answer, do: {:error, {:http_status, 500}}
end

defmodule Folio.MarketData.ChainTest.ThrottledSource do
  @moduledoc false
  def supports?(_arg), do: true
  def answer, do: {:error, :rate_limited}
end

defmodule Folio.MarketData.ChainTest.PickySource do
  @moduledoc false
  def supports?(arg), do: arg == :supported
  def answer, do: raise("an unsupported source must not be called")
end

defmodule Folio.MarketData.ChainTest.EmptySource do
  @moduledoc false
  def supports?(_arg), do: true
  def answer, do: {:ok, []}
end

defmodule Folio.MarketData.ChainTest.BareSource do
  @moduledoc false
  # Deliberately no supports?/1 - the FX source shape.
  def answer, do: {:ok, :from_bare_source}
end

defmodule Folio.MarketData.ChainTest.UntouchableSource do
  @moduledoc false
  def supports?(_arg), do: true
  def answer, do: raise("a rate-limited source must not be called")
end

defmodule Folio.MarketData.ChainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Folio.MarketData.Chain
  alias Folio.MarketData.ChainTest.BareSource
  alias Folio.MarketData.ChainTest.EmptySource
  alias Folio.MarketData.ChainTest.FailingSource
  alias Folio.MarketData.ChainTest.OkSource
  alias Folio.MarketData.ChainTest.PickySource
  alias Folio.MarketData.ChainTest.SecondSource
  alias Folio.MarketData.ChainTest.ThrottledSource
  alias Folio.MarketData.ChainTest.UntouchableSource
  alias Folio.MarketData.RateLimiter

  defp call, do: fn source -> source.answer() end

  defp attach_telemetry(context) do
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, context.test},
      [:folio, :market_data, :source],
      fn _event, _measurements, meta, _config -> send(test_pid, {:recorded, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, context.test}) end)
  end

  test "first success wins and later sources are not consulted" do
    assert {:ok, :from_ok_source} =
             Chain.run(:quote, [OkSource, UntouchableSource], :arg, call())
  end

  test "a failing source falls through to the next, with a log line" do
    log =
      capture_log(fn ->
        assert {:ok, :from_second_source} =
                 Chain.run(:quote, [FailingSource, SecondSource], :arg, call())
      end)

    assert log =~ "market data quote via failing_source failed"
    assert log =~ "http_status"
  end

  test "an unsupported source is skipped silently without being called" do
    log =
      capture_log(fn ->
        assert {:ok, :from_second_source} =
                 Chain.run(:quote, [PickySource, SecondSource], :not_supported, call())
      end)

    refute log =~ "picky_source"
  end

  test "an empty success falls through, and is the answer only when nothing beats it" do
    assert {:ok, :from_second_source} =
             Chain.run(:lookup, [EmptySource, SecondSource], :arg, call())

    assert {:ok, []} = Chain.run(:lookup, [EmptySource, PickySource], :not_supported, call())

    # A refusal is worth reporting over an empty answer.
    assert {:error, :rate_limited} =
             Chain.run(:lookup, [EmptySource, ThrottledSource], :arg, call())
  end

  test "a source without supports?/1 is treated as always supporting" do
    assert {:ok, :from_bare_source} = Chain.run(:fx, [BareSource], nil, call())
  end

  test "all sources unsupported" do
    assert {:error, :unsupported} = Chain.run(:quote, [PickySource], :not_supported, call())
    assert {:error, :unsupported} = Chain.run(:quote, [], :arg, call())
  end

  test "rate-limited outranks failed in the final error" do
    capture_log(fn ->
      assert {:error, :rate_limited} =
               Chain.run(:quote, [FailingSource, ThrottledSource], :arg, call())

      assert {:error, :rate_limited} =
               Chain.run(:quote, [ThrottledSource, FailingSource], :arg, call())
    end)
  end

  test "failed outranks unsupported in the final error" do
    capture_log(fn ->
      assert {:error, :failed} =
               Chain.run(:quote, [FailingSource, PickySource], :not_supported, call())
    end)
  end

  test "an empty token bucket skips the source without calling it", context do
    limiter_name = Module.concat(__MODULE__, context.test)

    start_supervised!(
      {RateLimiter,
       name: limiter_name,
       limits: [untouchable_source: [capacity: 1, per_minute: 1]],
       clock: fn -> 0 end}
    )

    assert RateLimiter.acquire(:untouchable_source, limiter_name) == :ok

    assert {:ok, :from_second_source} =
             Chain.run(:quote, [UntouchableSource, SecondSource], :arg, call(),
               limiter: limiter_name
             )
  end

  test "every attempt is recorded as telemetry", context do
    attach_telemetry(context)

    capture_log(fn ->
      Chain.run(:history, [PickySource, FailingSource, SecondSource], :arg, call())
    end)

    assert_receive {:recorded, %{source: :picky_source, concern: :history, outcome: :unsupported}}
    assert_receive {:recorded, %{source: :failing_source, concern: :history, outcome: :failed}}
    assert_receive {:recorded, %{source: :second_source, concern: :history, outcome: :ok}}
  end

  test "source_key/1 underscores the module basename" do
    assert Chain.source_key(Folio.MarketData.Sources.CoinGecko) == :coin_gecko
    assert Chain.source_key(OkSource) == :ok_source
  end
end
