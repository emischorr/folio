defmodule Folio.Portfolios do
  @moduledoc """
  Portfolios, memberships, and manually entered transactions.
  """

  import Ecto.Changeset, only: [get_field: 2, put_change: 3, validate_required: 2]
  import Ecto.Query

  alias Ecto.Multi
  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.Portfolios.Portfolio
  alias Folio.Portfolios.PortfolioMember
  alias Folio.Portfolios.Transaction
  alias Folio.Repo

  @type import_result :: %{
          inserted: non_neg_integer(),
          skipped: non_neg_integer(),
          invalid: [{pos_integer(), Ecto.Changeset.t()}]
        }

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

  @doc """
  Bulk-inserts transactions from an import. Rows that fail changeset
  validation are reported without blocking the rows that are valid; rows
  that collide on the `[:source, :external_id]` unique index (a repeat
  import) are silently skipped. A row whose insert fails for any other
  reason (e.g. a stale `asset_id`) is moved to `invalid` and the rest of the
  batch is retried, so one such row can never sink the whole import. Price/FX
  history is ensured once per distinct asset, at its earliest imported date,
  instead of once per row.
  """
  @spec import_transactions(pos_integer(), [map()]) :: import_result()
  def import_transactions(portfolio_id, attrs_list) do
    {valid, invalid} =
      attrs_list
      |> Enum.with_index(1)
      |> Enum.map(fn {attrs, row} ->
        {row, Transaction.changeset(%Transaction{portfolio_id: portfolio_id}, attrs)}
      end)
      |> Enum.split_with(fn {_row, changeset} -> changeset.valid? end)

    {inserted, insert_failures} = insert_all(valid)

    ensure_import_history(inserted)

    %{
      inserted: length(inserted),
      skipped: length(valid) - length(inserted) - length(insert_failures),
      invalid: invalid ++ insert_failures
    }
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

  defp get_asset(nil), do: nil
  defp get_asset(asset_id), do: Assets.get_asset(asset_id)

  defp insert_all([]), do: {[], []}

  defp insert_all(valid) do
    multi =
      Enum.reduce(valid, Multi.new(), fn {row, changeset}, multi ->
        Multi.insert(multi, {:transaction, row}, changeset,
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment,
             "(source, external_id) WHERE source IS NOT NULL AND external_id IS NOT NULL"}
        )
      end)

    case Repo.transaction(multi) do
      {:ok, results} ->
        {results |> Map.values() |> Enum.filter(& &1.id), []}

      {:error, {:transaction, failed_row}, failed_changeset, _changes_so_far} ->
        remaining = Enum.reject(valid, fn {row, _changeset} -> row == failed_row end)
        {inserted, failures} = insert_all(remaining)
        {inserted, [{failed_row, failed_changeset} | failures]}
    end
  end

  defp ensure_txn_history(%Transaction{} = transaction) do
    ensure_asset_history(transaction.asset_id, DateTime.to_date(transaction.executed_at))
  end

  defp ensure_import_history(transactions) do
    transactions
    |> Enum.group_by(& &1.asset_id, &DateTime.to_date(&1.executed_at))
    |> Enum.each(fn {asset_id, dates} ->
      ensure_asset_history(asset_id, Enum.min(dates, Date))
    end)
  end

  defp ensure_asset_history(asset_id, date) do
    %{quote_currency: quote_currency} = Assets.get_asset!(asset_id)
    :ok = MarketData.ensure_history(asset_id, date, quote_currency)
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
