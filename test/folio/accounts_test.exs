defmodule Folio.AccountsTest do
  use Folio.DataCase, async: true

  alias Folio.Accounts

  describe "ensure_admin/1" do
    test "creates the Admin user with a verifiable hash on first call" do
      admin = Accounts.ensure_admin("secret")

      assert admin.username == "Admin"
      assert Argon2.verify_pass("secret", admin.password_hash)
    end

    test "is idempotent and never overwrites the existing hash" do
      first = Accounts.ensure_admin("secret")
      second = Accounts.ensure_admin("different")

      assert second.id == first.id
      assert second.password_hash == first.password_hash
    end
  end

  describe "get_user_by_username/1" do
    test "matches case-insensitively via citext" do
      admin = Accounts.ensure_admin("secret")

      assert Accounts.get_user_by_username("admin").id == admin.id
      assert Accounts.get_user_by_username("ADMIN").id == admin.id
    end
  end

  describe "default_user!/0" do
    test "returns the Admin user once bootstrapped" do
      admin = Accounts.ensure_admin("secret")
      assert Accounts.default_user!().id == admin.id
    end

    test "raises when bootstrap has not run" do
      assert_raise RuntimeError, ~r/Bootstrap has not run/, fn -> Accounts.default_user!() end
    end
  end
end
