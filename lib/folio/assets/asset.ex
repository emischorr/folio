defmodule Folio.Assets.Asset do
  @moduledoc """
  A globally shared, tradable instrument, identified only by general,
  vendor-neutral facts. Securities: ISIN + MIC - the same ISIN on another
  venue is a different asset with a different price series - plus the
  exchange-local ticker. Crypto: symbol. No provider identifiers are ever
  stored here; each market-data source derives what it needs from these
  fields.

  Securities migrated from the vendor-identity era can lack parts of their
  identity (`unresolved?/1`); the changeset never produces such rows, and the
  UI offers a repair form (`identity_changeset/2`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Folio.Assets.Identifier
  alias Folio.MarketData.Markets

  @type t :: %__MODULE__{}
  @type kind :: :crypto | :stock | :etf

  schema "assets" do
    field :symbol, :string
    field :ticker, :string
    field :name, :string
    field :kind, Ecto.Enum, values: [:crypto, :stock, :etf]
    field :mic, :string
    field :quote_currency, :string
    field :isin, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating an asset from resolver output or manual entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:symbol, :ticker, :name, :kind, :mic, :quote_currency, :isin])
    |> validate_required([:name, :kind, :quote_currency])
    |> update_change(:quote_currency, &String.upcase/1)
    |> validate_format(:quote_currency, ~r/^[A-Z]{3}$/)
    |> kind_changeset()
  end

  @doc """
  Changeset for completing the identity of an unresolved security. Fields
  already stored are not cast, so a stored identifier is never overwritten.
  """
  @spec identity_changeset(t(), map()) :: Ecto.Changeset.t()
  def identity_changeset(asset, attrs) do
    asset
    |> cast(attrs, missing_identity_fields(asset))
    |> security_identity_changeset()
  end

  @doc "Whether a security still lacks part of its canonical identity."
  @spec unresolved?(t()) :: boolean()
  def unresolved?(%__MODULE__{kind: :crypto}), do: false

  def unresolved?(%__MODULE__{isin: isin, mic: mic, ticker: ticker}) do
    is_nil(isin) or is_nil(mic) or is_nil(ticker)
  end

  @doc "The user-facing code: exchange ticker, or symbol for crypto and legacy rows."
  @spec display_code(t()) :: String.t() | nil
  def display_code(%__MODULE__{ticker: ticker, symbol: symbol}), do: ticker || symbol

  defp kind_changeset(changeset) do
    case get_field(changeset, :kind) do
      :crypto ->
        changeset
        |> validate_required([:symbol])
        |> update_change(:symbol, &String.upcase/1)
        |> unique_constraint(:symbol, name: :assets_crypto_symbol_index)

      _security ->
        changeset
        |> validate_required([:ticker, :mic, :isin])
        |> security_identity_changeset()
    end
  end

  defp security_identity_changeset(changeset) do
    changeset
    |> update_change(:isin, &Identifier.normalize/1)
    |> validate_change(:isin, fn field, value ->
      if Identifier.isin?(value), do: [], else: [{field, "is not a valid ISIN"}]
    end)
    |> validate_inclusion(:mic, Markets.mics())
    |> unique_constraint([:isin, :mic], name: :assets_isin_mic_index)
  end

  defp missing_identity_fields(asset) do
    for field <- [:isin, :mic, :ticker], is_nil(Map.get(asset, field)), do: field
  end
end
