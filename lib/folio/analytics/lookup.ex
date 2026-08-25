defmodule Folio.Analytics.Lookup do
  @moduledoc """
  "Latest value at or before t" lookups over descending `{DateTime, Decimal}`
  series. Gaps (weekends, missing ticks) need no special handling: Friday's
  close simply serves Saturday.
  """

  @type series :: [{DateTime.t(), Decimal.t()}]

  @doc "The newest value at or before `t`, or nil when the series starts later."
  @spec at_or_before(series(), DateTime.t()) :: Decimal.t() | nil
  def at_or_before(descending_series, t) do
    Enum.find_value(descending_series, fn {at, value} ->
      if DateTime.compare(at, t) != :gt, do: value
    end)
  end

  @doc "The oldest value in the series, or nil when empty."
  @spec oldest(series()) :: Decimal.t() | nil
  def oldest([]), do: nil
  def oldest(descending_series), do: descending_series |> List.last() |> elem(1)
end
