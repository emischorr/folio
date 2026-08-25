defmodule Folio.Clients.HTTP do
  @moduledoc """
  Shared Req plumbing for all market-data clients.

  JSON numbers decode as `Decimal`s (`floats: :decimals`) so floats never
  enter the system; integers still decode as integers, hence `to_decimal/1`.
  Test env injects `plug: {Req.Test, Folio.Clients}` via `:req_options`.
  """

  @doc "Base request with Decimal JSON decoding, retries, and env overrides."
  @spec base(keyword()) :: Req.Request.t()
  def base(opts \\ []) do
    [decoders: [json: &Jason.decode(&1, floats: :decimals)], retry: :transient, max_retries: 2]
    |> Req.new()
    |> Req.merge(opts)
    |> Req.merge(Application.get_env(:folio, :req_options, []))
  end

  @doc "Maps a Req result to `{:ok, body}` or a normalized error."
  @spec handle({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, term()}
          | {:error, :rate_limited | {:http_status, pos_integer()} | {:network, Exception.t()}}
  def handle({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}

  def handle({:ok, %Req.Response{status: status}}) when status in [429, 999],
    do: {:error, :rate_limited}

  def handle({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  def handle({:error, exception}), do: {:error, {:network, exception}}

  @doc "Coerces a decoded JSON number (Decimal, integer, or numeric string) to Decimal."
  @spec to_decimal(Decimal.t() | integer() | String.t()) :: Decimal.t()
  def to_decimal(%Decimal{} = decimal), do: decimal
  def to_decimal(integer) when is_integer(integer), do: Decimal.new(integer)
  def to_decimal(string) when is_binary(string), do: Decimal.new(string)
end
