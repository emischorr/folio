defmodule Folio.MarketData.Backoff do
  @moduledoc """
  Bounded rate-limit backoff for the market-data workers.

  Oban's `{:snooze, _}` increments a job's `max_attempts` alongside `attempt`,
  so a worker that snoozes on every rate limit never exhausts its retries: it
  spins forever, holds a throttled endpoint under load, and never surfaces as
  a failure anywhere. Snoozes are counted off that inflated `max_attempts` and
  capped, after which the job is cancelled into a visible state.
  """

  @base_seconds 120
  @ceiling_seconds 1800

  @doc """
  Backoff for a rate-limited job: a doubling snooze until `limit` snoozes have
  been spent, then a cancellation. `declared_max_attempts` is the worker's own
  `:max_attempts`, which is what the snooze count is measured against.
  """
  @spec snooze_or_cancel(Oban.Job.t(), pos_integer(), pos_integer()) ::
          {:snooze, pos_integer()} | {:cancel, :rate_limited}
  def snooze_or_cancel(%Oban.Job{max_attempts: max_attempts}, declared_max_attempts, limit) do
    case max_attempts - declared_max_attempts do
      snoozes when snoozes >= limit -> {:cancel, :rate_limited}
      snoozes -> {:snooze, delay(snoozes)}
    end
  end

  defp delay(snoozes), do: min(@base_seconds * 2 ** snoozes, @ceiling_seconds)
end
