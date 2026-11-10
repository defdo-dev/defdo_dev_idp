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
  alias Defdo.DevIdp.PKCE
  alias Defdo.DevIdp.Store

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
    {id, secret} = credentials(conn)

    if secure_equal?(id, config.client.id) and secure_equal?(secret, config.client.secret),
      do: :ok,
      else: {:error, 401, "invalid_client"}
  end

  defp credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded | _rest] -> basic(encoded)
      _none -> {conn.params["client_id"], conn.params["client_secret"]}
    end
  end

  defp basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      {URI.decode_www_form(id), URI.decode_www_form(secret)}
    else
      _malformed -> {nil, nil}
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

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
      scope: stored.scope,
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
      "roles" => [profile.role]
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
