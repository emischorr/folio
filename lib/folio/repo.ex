defmodule Folio.Repo do
  use Ecto.Repo,
    otp_app: :folio,
    adapter: Ecto.Adapters.Postgres
end
