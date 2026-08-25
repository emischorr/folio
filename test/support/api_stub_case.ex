defmodule Folio.ApiStubCase do
  @moduledoc """
  Helpers for stubbing the market-data HTTP layer with `Req.Test`. Client
  modules run for real - parsing included - while requests are served from
  `test/support/api_responses/` or inline bodies.
  """

  import Plug.Conn

  @fixtures_dir "test/support/api_responses"

  @doc "Serves a captured JSON fixture file."
  @spec json_fixture(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def json_fixture(conn, name) do
    json_body(conn, File.read!(Path.join(@fixtures_dir, name)))
  end

  @doc "Serves a raw JSON string."
  @spec json_body(Plug.Conn.t(), String.t(), pos_integer()) :: Plug.Conn.t()
  def json_body(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> resp(status, body)
  end
end
