defmodule Folio.MarketData.Sources.HTTP do
  @moduledoc """
  Shared Req plumbing for all market-data sources.

  JSON numbers decode as `Decimal`s (`floats: :decimals`) so floats never
  enter the system; integers still decode as integers, hence `to_decimal/1`.
  Test env injects `plug: {Req.Test, ...}` via `:req_options`.
  """

  # 999 is Yahoo's own throttle code.
  @rate_limit_statuses [429, 999]

  @doc "Base request with Decimal JSON decoding, retries, and env overrides."
  @spec base(keyword()) :: Req.Request.t()
  def base(opts \\ []) do
    [
      decoders: [json: &Jason.decode(&1, floats: :decimals)],
      retry: &retry?/2,
      max_retries: 2
    ]
    |> Req.new()
    |> Req.merge(opts)
    |> Req.merge(Application.get_env(:folio, :req_options, []))
  end

  @doc """
  Retry predicate. Like Req's `:transient`, except a rate limit is never
  retried - free endpoints throttle per IP, and asking again immediately
  only deepens it. Callers fall through the chain on `:rate_limited` instead.
  """
  @spec retry?(Req.Request.t(), Req.Response.t() | Exception.t()) :: boolean()
  def retry?(_request, %Req.Response{status: status}) when status in @rate_limit_statuses,
    do: false

  def retry?(_request, %Req.Response{status: status}),
    do: status in [408, 500, 502, 503, 504]

  def retry?(_request, exception) when is_exception(exception), do: true

  @doc "Maps a Req result to `{:ok, body}` or a normalized error."
  @spec handle({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, term()}
          | {:error, :rate_limited | {:http_status, pos_integer()} | {:network, Exception.t()}}
  def handle({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}

  def handle({:ok, %Req.Response{status: status}}) when status in @rate_limit_statuses,
    do: {:error, :rate_limited}

  def handle({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  def handle({:error, exception}), do: {:error, {:network, exception}}

  @doc "Coerces a decoded JSON number (Decimal, integer, or numeric string) to Decimal."
  @spec to_decimal(Decimal.t() | integer() | String.t()) :: Decimal.t()
  def to_decimal(%Decimal{} = decimal), do: decimal
  def to_decimal(integer) when is_integer(integer), do: Decimal.new(integer)
  def to_decimal(string) when is_binary(string), do: Decimal.new(string)
end
