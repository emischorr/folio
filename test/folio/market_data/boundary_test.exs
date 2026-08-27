defmodule Folio.MarketData.BoundaryTest do
  @moduledoc """
  Enforces the market-data boundary: no module outside `lib/folio/market_data/`
  may reach past the `Folio.MarketData` public API (plus the public pure
  modules `Markets` and `Listing`) into sources, the chain, the rate limiter
  or the cache - and the pre-iteration `Folio.Clients` namespace must stay
  dead. A grep-based check on purpose: cheap, exact, and it fails with the
  offending file and line.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @context_root Path.join(@lib_root, "folio/market_data")

  @forbidden ~r/MarketData\.(Sources|Chain|RateLimiter|Cache|SourceStats)\b/
  @dead_namespace ~r/Folio\.Clients\b/

  test "no file outside the market-data context references its internals" do
    violations =
      for file <- outside_files(),
          {line, number} <- numbered_lines(file),
          Regex.match?(@forbidden, line),
          do: "#{Path.relative_to(file, @lib_root)}:#{number}: #{String.trim(line)}"

    assert violations == [], "market-data internals leaked:\n" <> Enum.join(violations, "\n")
  end

  test "the Folio.Clients namespace no longer exists anywhere" do
    violations =
      for file <- Path.wildcard(Path.join(@lib_root, "**/*.ex")),
          {line, number} <- numbered_lines(file),
          Regex.match?(@dead_namespace, line),
          do: "#{Path.relative_to(file, @lib_root)}:#{number}: #{String.trim(line)}"

    assert violations == [], "dead namespace referenced:\n" <> Enum.join(violations, "\n")
  end

  # The application module wires the context's processes into supervision;
  # that is infrastructure, not a consumer of the API.
  defp outside_files do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(
      &(String.starts_with?(&1, @context_root) or
          Path.basename(&1) == "application.ex")
    )
  end

  defp numbered_lines(file) do
    file |> File.read!() |> String.split("\n") |> Enum.with_index(1)
  end
end
