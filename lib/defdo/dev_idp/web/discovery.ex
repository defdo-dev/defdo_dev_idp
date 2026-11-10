defmodule Defdo.DevIdp.Web.Discovery do
  @moduledoc """
  The OpenID Connect Discovery 1.0 document.

  Nine OIDC keys, the dev-IdP mark (`defdo_idp_mark`) and `scopes_supported`. PKCE is `S256` only: `plain` is never
  advertised. The issuer uses the port the listener is actually bound to, so a
  server started on `port: 0` advertises a reachable URL.
  """

  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Mark

  @spec document(Config.t()) :: map()
  def document(%Config{} = config) do
    issuer = "http://localhost:#{Defdo.DevIdp.port()}"

    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/oauth/authorize",
      "token_endpoint" => issuer <> "/oauth/token",
      "userinfo_endpoint" => issuer <> "/openid/userinfo",
      "jwks_uri" => issuer <> "/.well-known/jwks.json",
      "introspection_endpoint" => issuer <> "/oauth/introspect",
      "response_types_supported" => ["code"],
      "code_challenge_methods_supported" => ["S256"],
      "grant_types_supported" => ["authorization_code"],
      Mark.field() => Mark.value(),
      "scopes_supported" => scopes(config)
    }
  end

  defp scopes(config) do
    config.profiles |> Enum.flat_map(& &1.scopes) |> Enum.uniq() |> Enum.sort()
  end
end
