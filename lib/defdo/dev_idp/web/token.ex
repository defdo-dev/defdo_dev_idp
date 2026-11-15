defmodule Defdo.DevIdp.Web.Token do
  @moduledoc """
  `POST /oauth/token`: exchanges an authorization code for an access token and
  a signed id_token.

  The client authenticates with `client_id` + `client_secret` in the body or
  with HTTP Basic. The code is single use; its `redirect_uri` and PKCE verifier
  must match what the authorize request stored.
  """

  import Plug.Conn

  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Keys
  alias Defdo.DevIdp.Mark
  alias Defdo.DevIdp.PKCE
  alias Defdo.DevIdp.Store
  alias Defdo.DevIdp.Web.ClientAuth

  @spec post(Plug.Conn.t()) :: Plug.Conn.t()
  def post(conn) do
    config = conn.assigns.config
    params = conn.params

    with :ok <- authenticate(conn, config),
         :ok <- check_grant_type(params),
         {:ok, stored} <- take_code(params["code"]),
         :ok <- check_redirect_uri(stored, params["redirect_uri"]),
         :ok <- check_verifier(stored, params["code_verifier"]),
         {:ok, profile} <- fetch_profile(config, stored.profile_key) do
      json(conn, 200, grant(config, stored, profile))
    else
      {:error, status, code} -> json(conn, status, %{error: code})
    end
  end

  defp authenticate(conn, config) do
    case ClientAuth.check(conn, config) do
      :ok -> :ok
      :error -> {:error, 401, "invalid_client"}
    end
  end

  defp check_grant_type(params) do
    if params["grant_type"] == "authorization_code",
      do: :ok,
      else: {:error, 400, "unsupported_grant_type"}
  end

  defp take_code(code) do
    case Store.take_code(code) do
      {:ok, stored} -> {:ok, stored}
      :error -> {:error, 400, "invalid_grant"}
    end
  end

  defp check_redirect_uri(stored, redirect_uri) do
    if is_binary(redirect_uri) and redirect_uri == stored.redirect_uri,
      do: :ok,
      else: {:error, 400, "invalid_grant"}
  end

  defp check_verifier(stored, verifier) do
    if PKCE.verify(verifier, stored.code_challenge), do: :ok, else: {:error, 400, "invalid_grant"}
  end

  defp fetch_profile(config, key) do
    case Enum.find(config.profiles, &(&1.key == key)) do
      nil -> {:error, 400, "invalid_grant"}
      profile -> {:ok, profile}
    end
  end

  defp grant(%Config{} = config, stored, profile) do
    token = Store.random()
    now = Store.now()

    Store.put_token(token, %{
      profile_key: profile.key,
      client_id: stored.client_id,
      scope: String.split(stored.scope, " ", trim: true),
      issued_at: now,
      expires_at: now + Store.token_ttl()
    })

    %{
      access_token: token,
      token_type: "Bearer",
      expires_in: Store.token_ttl(),
      scope: stored.scope,
      id_token: Keys.sign_id_token(claims(config, stored, profile, now))
    }
  end

  defp claims(config, stored, profile, now) do
    base = %{
      "iss" => "http://localhost:#{Defdo.DevIdp.port()}",
      "sub" => profile.sub,
      "aud" => config.client.id,
      "iat" => now,
      "exp" => now + Store.token_ttl(),
      "email" => profile.email,
      "name" => profile.name,
      "tenant_id" => profile.tenant_id,
      "roles" => [profile.role],
      Mark.field() => Mark.value()
    }

    if stored.nonce, do: Map.put(base, "nonce", stored.nonce), else: base
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end
end
