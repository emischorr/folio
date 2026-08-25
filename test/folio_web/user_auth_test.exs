defmodule FolioWeb.UserAuthTest do
  use FolioWeb.ConnCase, async: true

  alias Folio.Accounts
  alias Folio.AccountsFixtures
  alias FolioWeb.UserAuth

  setup %{conn: conn} do
    admin = Accounts.ensure_admin("secret")
    {:ok, conn: init_test_session(conn, %{}), admin: admin}
  end

  describe "fetch_current_user/2" do
    test "falls back to the default user and seeds the session", %{conn: conn, admin: admin} do
      conn = UserAuth.fetch_current_user(conn, [])

      assert conn.assigns.current_scope.user.id == admin.id
      assert Plug.Conn.get_session(conn, :user_id) == admin.id
    end

    test "uses the session's user when present", %{conn: conn} do
      other = AccountsFixtures.user_fixture()

      conn =
        conn
        |> Plug.Conn.put_session(:user_id, other.id)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_scope.user.id == other.id
    end

    test "recovers when the session points at a deleted user", %{conn: conn, admin: admin} do
      conn =
        conn
        |> Plug.Conn.put_session(:user_id, -1)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_scope.user.id == admin.id
    end
  end

  describe "on_mount/4" do
    test "assigns current_scope from the session", %{admin: admin} do
      other = AccountsFixtures.user_fixture()
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, socket} = UserAuth.on_mount(:default, %{}, %{"user_id" => other.id}, socket)
      assert socket.assigns.current_scope.user.id == other.id

      assert {:cont, socket} = UserAuth.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})
      assert socket.assigns.current_scope.user.id == admin.id
    end
  end
end
