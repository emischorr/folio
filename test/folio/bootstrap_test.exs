defmodule Folio.BootstrapTest do
  use Folio.DataCase, async: false

  alias Folio.Accounts
  alias Folio.Bootstrap
  alias Folio.Portfolios

  setup do
    original = Application.get_env(:folio, Folio.Bootstrap)
    on_exit(fn -> Application.put_env(:folio, Folio.Bootstrap, original) end)
    :ok
  end

  test "creates the Admin user and an owned EUR portfolio" do
    Application.put_env(:folio, Folio.Bootstrap, enabled: true, admin_password: "boot-secret")

    assert Bootstrap.run() == :ok

    admin = Accounts.get_user_by_username("Admin")
    assert Argon2.verify_pass("boot-secret", admin.password_hash)

    assert [portfolio] = Portfolios.list_portfolios(admin.id)
    assert portfolio.base_currency == "EUR"
    assert Portfolios.owns_portfolio?(admin.id)
  end

  test "is idempotent across repeated runs" do
    Application.put_env(:folio, Folio.Bootstrap, enabled: true, admin_password: "boot-secret")

    assert Bootstrap.run() == :ok
    assert Bootstrap.run() == :ok

    admin = Accounts.get_user_by_username("Admin")
    assert [_only_one] = Portfolios.list_portfolios(admin.id)
  end

  test "skips entirely when disabled" do
    Application.put_env(:folio, Folio.Bootstrap, enabled: false)

    assert Bootstrap.run() == :skipped
    refute Accounts.get_user_by_username("Admin")
  end
end
