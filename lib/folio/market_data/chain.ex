defmodule Folio.MarketData.Chain do
  @moduledoc """
  Generic fallback executor over an ordered list of source modules.

  For each source in turn: skip it silently when it does not support the
  request, skip it without calling when its token bucket is empty, otherwise
  call it - the first success wins. Every attempt is recorded as telemetry
  (`[:folio, :market_data, :source]`) so `Folio.MarketData.SourceStats` can
  make a silently broken source visible.

  Outcomes are distinguished deliberately: `:unsupported` is a non-event,
  `:failed` is logged, `:rate_limited` tells workers to snooze. An empty
  success (`{:ok, []}`) counts as answered but still falls through - another
  source may know the listing (OpenFIGI does not know every identifier, a
  venue may have no data for a range). When no source returns data, one empty
  answer makes the chain `{:ok, []}`; otherwise the worst outcome seen wins:
  rate_limited > failed > unsupported.
  """

  require Logger

  alias Folio.MarketData.RateLimiter

  @event [:folio, :market_data, :source]

  @error_rank %{unsupported: 0, empty: 1, failed: 2, rate_limited: 3}

  @type concern :: :lookup | :history | :quote | :fx
  @type outcome :: :ok | :unsupported | :rate_limited | :failed

  @doc """
  Runs `call` against the first supporting, in-budget source in `sources`.

  `support_arg` is handed to each source's `supports?/1`; a source without a
  `supports?/1` (the FX source) is treated as always supporting. Options:
  `:limiter` overrides the rate-limiter instance (tests).
  """
  @spec run(
          concern(),
          [module()],
          term(),
          (module() -> {:ok, term()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, term()} | {:error, :unsupported | :rate_limited | :failed}
  def run(concern, sources, support_arg, call, opts \\ []) do
    limiter = Keyword.get(opts, :limiter, RateLimiter)

    result =
      Enum.reduce_while(sources, :unsupported, fn source, worst ->
        case try_source(source, concern, support_arg, call, limiter) do
          {:ok, []} -> {:cont, worse(worst, :empty)}
          {:ok, result} -> {:halt, {:ok, result}}
          outcome -> {:cont, worse(worst, outcome)}
        end
      end)

    case result do
      {:ok, value} -> {:ok, value}
      :empty -> {:ok, []}
      error -> {:error, error}
    end
  end

  @doc "The telemetry/rate-limit key of a source module, e.g. `:coin_gecko`."
  @spec source_key(module()) :: atom()
  def source_key(source) do
    source
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp try_source(source, concern, support_arg, call, limiter) do
    key = source_key(source)

    cond do
      not supported?(source, support_arg) ->
        record(key, concern, :unsupported)

      RateLimiter.acquire(key, limiter) == {:error, :rate_limited} ->
        record(key, concern, :rate_limited)

      true ->
        attempt(source, key, concern, call)
    end
  end

  defp attempt(source, key, concern, call) do
    case call.(source) do
      {:ok, result} ->
        record(key, concern, :ok)
        {:ok, result}

      {:error, :rate_limited} ->
        record(key, concern, :rate_limited)

      {:error, reason} ->
        Logger.warning("market data #{concern} via #{key} failed: #{inspect(reason)}")
        record(key, concern, :failed)
    end
  end

  defp supported?(source, support_arg) do
    Code.ensure_loaded?(source) and
      (not function_exported?(source, :supports?, 1) or source.supports?(support_arg))
  end

  defp record(key, concern, outcome) do
    :telemetry.execute(@event, %{count: 1}, %{source: key, concern: concern, outcome: outcome})
    outcome
  end

  defp worse(left, right) do
    if @error_rank[right] > @error_rank[left], do: right, else: left
  end
end
