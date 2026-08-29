defmodule Folio.Assets do
  @moduledoc """
  Globally shared assets and their resolution from user-typed names,
  tickers or identifiers. Assets carry only vendor-neutral identity
  (ISIN + MIC + ticker for securities, symbol for crypto); everything
  provider-specific lives behind `Folio.MarketData`.
  """

  import Ecto.Query

  alias Folio.Assets.Asset
  alias Folio.Assets.Candidate
  alias Folio.Assets.Identifier
  alias Folio.Assets.Resolver
  alias Folio.MarketData
  alias Folio.MarketData.Listing
  alias Folio.Repo

  @initial_history_days 30
  @search_limit 20

  @doc "Days of price history fetched when an asset is first created."
  @spec initial_history_days() :: pos_integer()
  def initial_history_days, do: @initial_history_days

  @doc "Fetches an asset by id, raising if absent."
  @spec get_asset!(pos_integer()) :: Asset.t()
  def get_asset!(id), do: Repo.get!(Asset, id)

  @doc "Fetches an asset by id, or nil."
  @spec get_asset(pos_integer()) :: Asset.t() | nil
  def get_asset(id), do: Repo.get(Asset, id)

  @doc "All assets, alphabetical by symbol."
  @spec list_assets() :: [Asset.t()]
  def list_assets, do: Repo.all(from a in Asset, order_by: [asc: a.symbol])

  @doc """
  Local search: substring match over ticker, symbol and name
  (case-insensitive), or an exact match on ISIN.
  """
  @spec search_local(String.t()) :: [Asset.t()]
  def search_local(query) do
    pattern = "%#{sanitize_like(query)}%"
    identifier = Identifier.normalize(query)

    Repo.all(
      from a in Asset,
        where:
          ilike(a.ticker, ^pattern) or ilike(a.symbol, ^pattern) or ilike(a.name, ^pattern) or
            a.isin == ^identifier,
        order_by: [asc: a.name],
        limit: ^@search_limit
    )
  end

  @doc """
  Resolves a user-typed name, ticker, ISIN or WKN into candidates (local
  matches first) plus the health of the remote providers. Remote failures
  degrade to local-only results with a non-`:ok` status.
  """
  @spec resolve(String.t()) :: %{candidates: [Candidate.t()], status: Resolver.status()}
  def resolve(query), do: Resolver.resolve(query)

  @doc """
  Fetches an asset by its vendor-neutral identity: symbol for crypto,
  ISIN + MIC for securities. Used to find-or-create an asset without
  reaching into the caller's domain for a full asset struct.
  """
  @spec get_by_identity(map()) :: Asset.t() | nil
  def get_by_identity(%{kind: :crypto, symbol: symbol}) do
    Repo.get_by(Asset, kind: :crypto, symbol: String.upcase(symbol))
  end

  def get_by_identity(%{isin: isin, mic: mic}) when is_binary(isin) and is_binary(mic) do
    Repo.get_by(Asset, isin: Identifier.normalize(isin), mic: mic)
  end

  @doc """
  Creates an asset from a resolver candidate or manual entry - the attrs are
  the same vendor-neutral identity either way - and enqueues an initial price
  backfill.
  """
  @spec create_asset(map()) :: {:ok, Asset.t()} | {:error, Ecto.Changeset.t()}
  def create_asset(attrs) do
    with {:ok, asset} <- %Asset{} |> Asset.changeset(attrs) |> Repo.insert() do
      from_date = Date.add(Date.utc_today(), -@initial_history_days)
      :ok = MarketData.ensure_history(asset.id, from_date, asset.quote_currency)
      {:ok, asset}
    end
  end

  @doc """
  Completes the identity of an existing asset (ISIN, MIC, ticker). Only
  fields currently blank on the asset are written, so a stored identifier is
  never silently overwritten. When the asset becomes fully resolved, its
  price backfill is enqueued.
  """
  @spec resolve_identity(pos_integer(), map()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()} | :noop
  def resolve_identity(asset_id, attrs) do
    changeset = asset_id |> get_asset!() |> Asset.identity_changeset(attrs)

    if changeset.changes == %{} do
      :noop
    else
      with {:ok, updated} <- Repo.update(changeset) do
        ensure_history_when_resolved(updated)
        {:ok, updated}
      end
    end
  end

  @doc "The vendor-neutral listing shape `Folio.MarketData` works with."
  @spec listing(Asset.t()) :: Listing.t()
  def listing(%Asset{} = asset) do
    Listing.new(%{
      asset_id: asset.id,
      kind: asset.kind,
      symbol: asset.symbol,
      ticker: asset.ticker,
      isin: asset.isin,
      mic: asset.mic,
      quote_currency: asset.quote_currency
    })
  end

  @doc "Distinct quote currencies across all assets."
  @spec quote_currencies() :: [String.t()]
  def quote_currencies do
    Repo.all(from a in Asset, distinct: true, select: a.quote_currency)
  end

  @doc """
  Assets the periodic refresh should poll: crypto by kind, securities by kind
  minus those still missing identity (nothing can fetch an unresolved asset).
  """
  @spec list_refreshable(:crypto | :security) :: [Asset.t()]
  def list_refreshable(:crypto) do
    Repo.all(from a in Asset, where: a.kind == :crypto, order_by: [asc: a.id])
  end

  def list_refreshable(:security) do
    Repo.all(
      from a in Asset,
        where:
          a.kind != :crypto and not is_nil(a.isin) and not is_nil(a.mic) and not is_nil(a.ticker),
        order_by: [asc: a.id]
    )
  end

  defp ensure_history_when_resolved(asset) do
    unless Asset.unresolved?(asset) do
      from_date = Date.add(Date.utc_today(), -@initial_history_days)
      :ok = MarketData.ensure_history(asset.id, from_date, asset.quote_currency)
    end
  end

  defp sanitize_like(query) do
    String.replace(query, ~r/[\\%_]/, fn char -> "\\" <> char end)
  end
end
