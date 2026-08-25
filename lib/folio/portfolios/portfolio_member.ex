defmodule Folio.Portfolios.PortfolioMember do
  @moduledoc """
  Membership of a user in a portfolio. `:owner` is just a role, so shared
  portfolios need no special path.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type role :: :owner | :editor | :viewer

  schema "portfolio_members" do
    field :role, Ecto.Enum, values: [:owner, :editor, :viewer]

    belongs_to :portfolio, Folio.Portfolios.Portfolio
    belongs_to :user, Folio.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a membership; portfolio and user ids are set by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:portfolio_id, :user_id])
    |> foreign_key_constraint(:portfolio_id)
    |> foreign_key_constraint(:user_id)
  end
end
