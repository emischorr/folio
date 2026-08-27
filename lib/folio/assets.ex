defmodule Folio.Assets do
  @moduledoc """
  Globally shared assets and their resolution from user-typed names or
  tickers. Technical price-source fields are filled by the resolver or by
  manual candidate construction, never typed directly by users.
  """

  import Ecto.Query

  alias Folio.Assets.Asset
  alias Folio.Assets.Candidate
  alias Folio.Assets.Identifier
  alias Folio.Assets.Resolver
  alias Folio.MarketData
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
  Local search: substring match over symbol and name (case-insensitive), or
  an exact match on ISIN or WKN.
  """
  @spec search_local(String.t()) :: [Asset.t()]
  def search_local(query) do
    pattern = "%#{sanitize_like(query)}%"
    identifier = Identifier.normalize(query)

    Repo.all(
      from a in Asset,
        where:
          ilike(a.symbol, ^pattern) or ilike(a.name, ^pattern) or a.isin == ^identifier or
            a.wkn == ^identifier,
        order_by: [asc: a.symbol],
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
  Creates an asset from a resolver candidate (or an equivalent manually built
  one), storing the source mapping, and enqueues an initial price backfill.
  Returns the existing asset when the source mapping is already present.
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
  Creates an asset from manual entry (remote search unavailable): the user
  supplies symbol, name, kind, quote currency and optionally exchange. The
  source mapping is derived - equities map to the equity provider keyed by
  ticker; crypto requires the provider's coin id as `:source_id`.
  """
  @spec create_manual_asset(map()) :: {:ok, Asset.t()} | {:error, Ecto.Changeset.t()}
  def create_manual_asset(%{kind: :crypto} = attrs) do
    create_asset(Map.put(attrs, :price_source, :coingecko))
  end

  def create_manual_asset(%{symbol: symbol} = attrs) do
    attrs
    |> Map.put(:price_source, :yahoo)
    |> Map.put(:source_id, symbol)
    |> create_asset()
  end

  @doc """
  Fills in the identifiers of an existing asset. Only keys that are present
  and currently blank on the asset are written, so a stored identifier is
  never silently overwritten.
  """
  @spec update_identifiers(pos_integer(), map()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()} | :noop
  def update_identifiers(asset_id, attrs) do
    asset = get_asset!(asset_id)

    case fillable_identifiers(asset, attrs) do
      changes when map_size(changes) == 0 -> :noop
      changes -> asset |> Asset.identifiers_changeset(changes) |> Repo.update()
    end
  end

  @doc "Distinct quote currencies across all assets."
  @spec quote_currencies() :: [String.t()]
  def quote_currencies do
    Repo.all(from a in Asset, distinct: true, select: a.quote_currency)
  end

  @doc "Assets fetched from the given source (`:coingecko` or `:yahoo`)."
  @spec list_assets_by_source(Asset.price_source()) :: [Asset.t()]
  def list_assets_by_source(price_source) do
    Repo.all(from a in Asset, where: a.price_source == ^price_source, order_by: [asc: a.id])
  end

  defp fillable_identifiers(%{isin: isin, wkn: wkn}, attrs) do
    for {field, stored} <- [isin: isin, wkn: wkn],
        is_nil(stored),
        value = attrs[field],
        not is_nil(value),
        into: %{},
        do: {field, value}
  end

  defp sanitize_like(query) do
    String.replace(query, ~r/[\\%_]/, fn char -> "\\" <> char end)
  end
end
