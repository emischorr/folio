defmodule Folio.Portfolios do
  @moduledoc """
  Portfolios, memberships, and manually entered transactions.
  """

  import Ecto.Changeset, only: [get_field: 2, put_change: 3, validate_required: 2]
  import Ecto.Query

  alias Ecto.Multi
  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.Portfolios.AssetGroup
  alias Folio.Portfolios.AssetGroupMember
  alias Folio.Portfolios.Portfolio
  alias Folio.Portfolios.PortfolioMember
  alias Folio.Portfolios.Transaction
  alias Folio.Repo

  @doc "Fetches a portfolio by id, raising if absent."
  @spec get_portfolio!(pos_integer()) :: Portfolio.t()
  def get_portfolio!(id), do: Repo.get!(Portfolio, id)

  @doc "All portfolios the user is a member of, oldest first."
  @spec list_portfolios(pos_integer()) :: [Portfolio.t()]
  def list_portfolios(user_id) do
    Repo.all(
      from p in Portfolio,
        join: m in PortfolioMember,
        on: m.portfolio_id == p.id,
        where: m.user_id == ^user_id,
        order_by: [asc: p.id]
    )
  end

  @doc "The user's first portfolio (the one the dashboard shows), or nil."
  @spec default_portfolio_for(pos_integer()) :: Portfolio.t() | nil
  def default_portfolio_for(user_id) do
    user_id |> list_portfolios() |> List.first()
  end

  @doc "Whether the user has an `:owner` membership in any portfolio."
  @spec owns_portfolio?(pos_integer()) :: boolean()
  def owns_portfolio?(user_id) do
    Repo.exists?(from m in PortfolioMember, where: m.user_id == ^user_id and m.role == :owner)
  end

  @doc "Creates a portfolio with the given user as its owner, atomically."
  @spec create_portfolio(map(), pos_integer()) ::
          {:ok, Portfolio.t()} | {:error, Ecto.Changeset.t()}
  def create_portfolio(attrs, owner_user_id) do
    Multi.new()
    |> Multi.insert(:portfolio, Portfolio.changeset(%Portfolio{}, attrs))
    |> Multi.insert(:owner, fn %{portfolio: portfolio} ->
      %PortfolioMember{portfolio_id: portfolio.id, user_id: owner_user_id}
      |> PortfolioMember.changeset(%{role: :owner})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{portfolio: portfolio}} -> {:ok, portfolio}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Creates a transaction in the portfolio. `currency` defaults to the asset's
  quote currency. Ensures price/FX history covers the execution date by
  enqueueing backfills when needed.
  """
  @spec create_transaction(pos_integer(), map()) ::
          {:ok, Transaction.t()} | {:error, Ecto.Changeset.t()}
  def create_transaction(portfolio_id, attrs) do
    changeset = Transaction.changeset(%Transaction{portfolio_id: portfolio_id}, attrs)
    asset = changeset |> get_field(:asset_id) |> get_asset()

    with {:ok, transaction} <- changeset |> default_currency(asset) |> Repo.insert() do
      ensure_txn_history(transaction)
      {:ok, transaction}
    end
  end

  @doc "Fetches a transaction by id scoped to the portfolio, raising if absent."
  @spec get_transaction!(pos_integer(), pos_integer()) :: Transaction.t()
  def get_transaction!(portfolio_id, id) do
    Repo.get_by!(Transaction, id: id, portfolio_id: portfolio_id)
  end

  @doc "Changeset for creating or editing a transaction (form validation)."
  @spec change_transaction(Transaction.t(), map()) :: Ecto.Changeset.t()
  def change_transaction(%Transaction{} = transaction, attrs \\ %{}) do
    Transaction.changeset(transaction, attrs)
  end

  @doc """
  Updates a transaction. Re-runs the history coverage check afterwards, so
  moving `executed_at` earlier still gets price/FX data backfilled.
  """
  @spec update_transaction(Transaction.t(), map()) ::
          {:ok, Transaction.t()} | {:error, Ecto.Changeset.t()}
  def update_transaction(%Transaction{} = transaction, attrs) do
    with {:ok, updated} <- transaction |> Transaction.changeset(attrs) |> Repo.update() do
      ensure_txn_history(updated)
      {:ok, updated}
    end
  end

  @doc "Whether the portfolio has any transactions."
  @spec any_transactions?(pos_integer()) :: boolean()
  def any_transactions?(portfolio_id) do
    Repo.exists?(from t in Transaction, where: t.portfolio_id == ^portfolio_id)
  end

  @doc "Transactions of a portfolio, oldest first. Options: `:asset_id`."
  @spec list_transactions(pos_integer(), keyword()) :: [Transaction.t()]
  def list_transactions(portfolio_id, opts \\ []) do
    from(t in Transaction,
      where: t.portfolio_id == ^portfolio_id,
      order_by: [asc: t.executed_at, asc: t.id]
    )
    |> scope_asset(opts[:asset_id])
    |> Repo.all()
  end

  @doc "Deletes a transaction."
  @spec delete_transaction(Transaction.t()) :: {:ok, Transaction.t()}
  def delete_transaction(%Transaction{} = transaction), do: Repo.delete(transaction)

  @doc "Distinct currencies appearing on any transaction."
  @spec transaction_currencies() :: [String.t()]
  def transaction_currencies do
    Repo.all(from t in Transaction, distinct: true, select: t.currency)
  end

  @doc "The earliest execution date across all transactions for an asset, or nil."
  @spec earliest_transaction_date(pos_integer()) :: Date.t() | nil
  def earliest_transaction_date(asset_id) do
    earliest =
      Repo.one(
        from t in Transaction,
          where: t.asset_id == ^asset_id,
          order_by: [asc: t.executed_at],
          limit: 1,
          select: t.executed_at
      )

    if earliest, do: DateTime.to_date(earliest)
  end

  @doc "Groups in the portfolio, ordered by name."
  @spec list_asset_groups(pos_integer()) :: [AssetGroup.t()]
  def list_asset_groups(portfolio_id) do
    Repo.all(
      from g in AssetGroup, where: g.portfolio_id == ^portfolio_id, order_by: [asc: g.name]
    )
  end

  @doc "Maps every grouped asset in the portfolio to its group, for bulk dashboard lookup."
  @spec asset_group_by_asset(pos_integer()) :: %{pos_integer() => AssetGroup.t()}
  def asset_group_by_asset(portfolio_id) do
    from(m in AssetGroupMember,
      join: g in AssetGroup,
      on: g.id == m.asset_group_id,
      where: m.portfolio_id == ^portfolio_id,
      select: {m.asset_id, g}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The group the asset is currently in, within the portfolio, or nil."
  @spec get_asset_group_for_asset(pos_integer(), pos_integer()) :: AssetGroup.t() | nil
  def get_asset_group_for_asset(portfolio_id, asset_id) do
    Repo.one(
      from m in AssetGroupMember,
        join: g in AssetGroup,
        on: g.id == m.asset_group_id,
        where: m.portfolio_id == ^portfolio_id and m.asset_id == ^asset_id,
        select: g
    )
  end

  @doc "Creates a group in the portfolio."
  @spec create_asset_group(pos_integer(), map()) ::
          {:ok, AssetGroup.t()} | {:error, Ecto.Changeset.t()}
  def create_asset_group(portfolio_id, attrs) do
    %AssetGroup{portfolio_id: portfolio_id}
    |> AssetGroup.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Changeset for creating or renaming a group (form validation)."
  @spec change_asset_group(AssetGroup.t(), map()) :: Ecto.Changeset.t()
  def change_asset_group(asset_group \\ %AssetGroup{}, attrs \\ %{}) do
    AssetGroup.changeset(asset_group, attrs)
  end

  @doc """
  Assigns the asset to the group, scoped to the portfolio. Reassigns (moves
  the asset out of any prior group) on conflict. `asset_group_id` must belong
  to `portfolio_id`, or this raises, so callers can't cross-wire a group from
  a different portfolio.
  """
  @spec assign_asset_to_group(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, AssetGroup.t()} | {:error, Ecto.Changeset.t()}
  def assign_asset_to_group(portfolio_id, asset_id, asset_group_id) do
    group = Repo.get_by!(AssetGroup, id: asset_group_id, portfolio_id: portfolio_id)

    changeset =
      AssetGroupMember.changeset(
        %AssetGroupMember{
          asset_group_id: group.id,
          portfolio_id: portfolio_id,
          asset_id: asset_id
        },
        %{}
      )

    case Repo.insert(changeset,
           on_conflict: [set: [asset_group_id: group.id, updated_at: DateTime.utc_now()]],
           conflict_target: [:portfolio_id, :asset_id]
         ) do
      {:ok, _member} -> {:ok, group}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Creates a group and assigns the asset to it, atomically. Fails with the
  group changeset if the name is blank or already taken in the portfolio.
  """
  @spec create_asset_group_and_assign(pos_integer(), pos_integer(), map()) ::
          {:ok, AssetGroup.t()} | {:error, Ecto.Changeset.t()}
  def create_asset_group_and_assign(portfolio_id, asset_id, attrs) do
    Multi.new()
    |> Multi.insert(:group, AssetGroup.changeset(%AssetGroup{portfolio_id: portfolio_id}, attrs))
    |> Multi.insert(:member, fn %{group: group} ->
      AssetGroupMember.changeset(
        %AssetGroupMember{
          asset_group_id: group.id,
          portfolio_id: portfolio_id,
          asset_id: asset_id
        },
        %{}
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{group: group}} -> {:ok, group}
      {:error, :group, changeset, _changes} -> {:error, changeset}
      {:error, :member, changeset, _changes} -> {:error, changeset}
    end
  end

  defp get_asset(nil), do: nil
  defp get_asset(asset_id), do: Assets.get_asset(asset_id)

  defp ensure_txn_history(%Transaction{} = transaction) do
    %{quote_currency: quote_currency} = Assets.get_asset!(transaction.asset_id)

    :ok =
      MarketData.ensure_history(
        transaction.asset_id,
        DateTime.to_date(transaction.executed_at),
        quote_currency
      )
  end

  defp default_currency(changeset, asset) do
    case {get_field(changeset, :currency), asset} do
      {nil, %{quote_currency: currency}} -> put_change(changeset, :currency, currency)
      _other -> validate_required(changeset, [:currency])
    end
  end

  defp scope_asset(query, nil), do: query
  defp scope_asset(query, asset_id), do: where(query, [t], t.asset_id == ^asset_id)
end
