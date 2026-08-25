defmodule FolioWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FolioWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FolioWeb.Endpoint

      use FolioWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import FolioWeb.ConnCase

      use Oban.Testing, repo: Folio.Repo
    end
  end

  setup tags do
    Folio.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates the default Admin user with a portfolio, as `Folio.Bootstrap` would
  in production (it is disabled in test). Returns `%{user: user, portfolio:
  portfolio}` for use as a setup callback.
  """
  def bootstrap_default_user(_context) do
    user = Folio.Accounts.ensure_admin("secret")

    portfolio =
      Folio.Portfolios.default_portfolio_for(user.id) ||
        elem(Folio.Portfolios.create_portfolio(%{name: "Portfolio"}, user.id), 1)

    %{user: user, portfolio: portfolio}
  end
end
