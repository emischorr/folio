defmodule FolioWeb.PageController do
  use FolioWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
