defmodule Folio.Accounts.User do
  @moduledoc """
  A person using the app. Identified by id; `username` is unique
  (case-insensitive via citext). No email by design.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :password_hash, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a user; `password_hash` must already be hashed."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username])
    |> validate_required([:username])
    |> validate_length(:username, min: 1, max: 80)
    |> unique_constraint(:username)
    |> put_hash(attrs)
  end

  defp put_hash(changeset, %{password_hash: hash}) when is_binary(hash) do
    put_change(changeset, :password_hash, hash)
  end

  defp put_hash(changeset, _attrs), do: validate_required(changeset, [:password_hash])
end
