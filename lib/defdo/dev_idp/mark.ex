defmodule Defdo.DevIdp.Mark do
  @moduledoc """
  The mark this dev IdP declares about itself.

  defdo_auth_client refuses any identity provider carrying this mark outside
  `:dev` and `:test`. The dev IdP states it in every place that client reads:
  the discovery document, each id_token, the userinfo and introspection
  answers (field `defdo_idp_mark`), and every `Site` record the seed writes
  (field `idp_mark`).

  The mark is self-declared: it catches a dev IdP pointed at from production
  by mistake. It is not a defence against an attacker, who omits it.
  """

  @value "defdo-dev-idp"
  @field "defdo_idp_mark"
  @record_field "idp_mark"

  @doc "The mark's value."
  @spec value() :: String.t()
  def value, do: @value

  @doc "The field name in discovery, id_token, userinfo and introspection."
  @spec field() :: String.t()
  def field, do: @field

  @doc "The field name in a `Site` record."
  @spec record_field() :: String.t()
  def record_field, do: @record_field
end
