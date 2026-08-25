defmodule Folio.Accounts do
  @moduledoc """
  Users. There is no registration or login yet; the only user is the
  bootstrapped Admin (see `Folio.Bootstrap`).
  """

  import Ecto.Query

  alias Folio.Accounts.User
  alias Folio.Repo

  @admin_username "Admin"

  @doc "Fetches a user by id, or nil."
  @spec get_user(pos_integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc "Fetches a user by username (case-insensitive), or nil."
  @spec get_user_by_username(String.t()) :: User.t() | nil
  def get_user_by_username(username) do
    Repo.one(from u in User, where: u.username == ^username)
  end

  @doc """
  The user requests fall back to while there is no login: the bootstrapped
  Admin. Raises if bootstrap has not run.
  """
  @spec default_user!() :: User.t()
  def default_user! do
    get_user_by_username(@admin_username) ||
      raise "default user missing - Folio.Bootstrap has not run"
  end

  @doc """
  Idempotently creates the Admin user, hashing `password` on first creation
  only. Returns the (existing or new) user.
  """
  @spec ensure_admin(String.t()) :: User.t()
  def ensure_admin(password) when is_binary(password) do
    case get_user_by_username(@admin_username) do
      nil ->
        %User{}
        |> User.changeset(%{
          username: @admin_username,
          password_hash: Argon2.hash_pwd_salt(password)
        })
        |> Repo.insert!(on_conflict: :nothing, conflict_target: :username)

        # Re-fetch: with on_conflict: :nothing a concurrent insert wins silently.
        get_user_by_username(@admin_username)

      user ->
        user
    end
  end
end
