defmodule Folio.Accounts.Scope do
  @moduledoc """
  The identity a request acts as. Carried in `conn.assigns.current_scope` /
  LiveView `@current_scope`; a real login flow will only change how it is built.
  """

  alias Folio.Accounts.User

  defstruct [:user]

  @type t :: %__MODULE__{user: User.t()}

  @doc "Builds a scope for the given user."
  @spec for_user(User.t()) :: t()
  def for_user(%User{} = user), do: %__MODULE__{user: user}
end
