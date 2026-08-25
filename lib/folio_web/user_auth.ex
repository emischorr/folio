defmodule FolioWeb.UserAuth do
  @moduledoc """
  Auth-shaped session handling without a login flow: every request acts as the
  user id stored in the session, falling back to the bootstrapped Admin. A real
  login flow later replaces only how the session gets its user id.
  """

  import Plug.Conn

  alias Folio.Accounts
  alias Folio.Accounts.Scope

  @doc """
  Plug: assigns `:current_scope` from the session's user id, seeding the
  session with the default user when absent.
  """
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    case get_session(conn, :user_id) && Accounts.get_user(get_session(conn, :user_id)) do
      nil ->
        user = Accounts.default_user!()

        conn
        |> put_session(:user_id, user.id)
        |> assign(:current_scope, Scope.for_user(user))

      user ->
        assign(conn, :current_scope, Scope.for_user(user))
    end
  end

  @doc """
  LiveView hook: assigns `:current_scope` the same way as the plug (without
  writing the session). Attach via
  `live_session ..., on_mount: [{FolioWeb.UserAuth, :default}]`.
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    user =
      (session["user_id"] && Accounts.get_user(session["user_id"])) || Accounts.default_user!()

    {:cont, Phoenix.Component.assign(socket, :current_scope, Scope.for_user(user))}
  end
end
