defmodule Defdo.DevIdp.Web.Discovery do
  @moduledoc """
  The OpenID Connect discovery document.

  Nine keys plus `scopes_supported`. The issuer uses the port the listener is
  actually bound to, so a server started on `port: 0` advertises a reachable URL.
  """

  alias Defdo.DevIdp.Config

  @spec document(Config.t()) :: map()
  def document(%Config{} = config) do
    issuer = "http://localhost:#{Defdo.DevIdp.port()}"

    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/oauth/authorize",
      "token_endpoint" => issuer <> "/oauth/token",
      "userinfo_endpoint" => issuer <> "/openid/userinfo",
      "jwks_uri" => issuer <> "/.well-known/jwks.json",
      "response_types_supported" => ["code"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["RS256"],
      "code_challenge_methods_supported" => ["S256"],
      "scopes_supported" => scopes(config)
    }
  end

  defp scopes(config) do
    config.profiles |> Enum.flat_map(& &1.scopes) |> Enum.uniq() |> Enum.sort()
  end
end
