defmodule Folio.AccountsFixtures do
  @moduledoc "Test fixtures for users."

  alias Folio.Accounts.User
  alias Folio.Repo

  @doc "Inserts a user with a unique username."
  @spec user_fixture(map()) :: User.t()
  def user_fixture(attrs \\ %{}) do
    username = Map.get(attrs, :username, "user-#{System.unique_integer([:positive])}")

    Repo.insert!(%User{username: username, password_hash: Argon2.hash_pwd_salt("password")})
  end
end
