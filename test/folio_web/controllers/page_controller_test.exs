defmodule FolioWeb.PageControllerTest do
  use FolioWeb.ConnCase

  setup do
    # The browser pipeline's fetch_current_user falls back to the
    # bootstrapped default user.
    Folio.Accounts.ensure_admin("secret")
    :ok
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
