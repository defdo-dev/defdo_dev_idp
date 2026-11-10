defmodule Defdo.DevIdp.Web.Token do
  @moduledoc """
  `POST /oauth/token`.

    * `grant_type=authorization_code` — the login client exchanges a code for an
      access token and a signed id_token. The code is single use; its
      `redirect_uri` and PKCE verifier must match what authorize stored.
    * `grant_type=client_credentials` — the dev service client (`<id>-svc`)
      mints a machine token with the app record's service scopes. The login
      client asking for this grant is `unauthorized_client`.

  The client authenticates with `client_id` + `client_secret` in the body or
  with HTTP Basic.
  """

  import Plug.Conn

  alias Defdo.AuthClient.Site
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Keys
  alias Defdo.DevIdp.Mark
  alias Defdo.DevIdp.PKCE
  alias Defdo.DevIdp.Store
  alias Defdo.DevIdp.Web.ClientAuth

  @default_service_scopes ["api:admin"]

  @spec post(Plug.Conn.t()) :: Plug.Conn.t()
  def post(conn) do
    config = conn.assigns.config

    case ClientAuth.identify(conn, config) do
      {:ok, client} ->
        respond(conn, grant(client, conn.params["grant_type"], conn.params, config))

      :error ->
        json(conn, 401, %{error: "invalid_client"})
    end
  end

  defp respond(conn, {:ok, body}), do: json(conn, 200, body)
  defp respond(conn, {:error, status, code}), do: json(conn, status, %{error: code})

  defp grant(:login, "authorization_code", params, config), do: exchange_code(params, config)
  defp grant(:service, "client_credentials", _params, config), do: {:ok, service_grant(config)}

  defp grant(_client, "client_credentials", _params, _config),
    do: {:error, 400, "unauthorized_client"}

  defp grant(_client, "authorization_code", _params, _config),
    do: {:error, 400, "unauthorized_client"}

  defp grant(_client, _grant_type, _params, _config), do: {:error, 400, "unsupported_grant_type"}

  # ── authorization_code ──────────────────────────────────────────────────────

  defp exchange_code(params, config) do
    with {:ok, stored} <- take_code(params["code"]),
         :ok <- check_redirect_uri(stored, params["redirect_uri"]),
         :ok <- check_verifier(stored, params["code_verifier"]),
         {:ok, profile} <- fetch_profile(config, stored.profile_key) do
      {:ok, login_grant(config, stored, profile)}
    end
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

  defp login_grant(%Config{} = config, stored, profile) do
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

  # ── client_credentials ──────────────────────────────────────────────────────

  defp service_grant(config) do
    token = Store.random()
    now = Store.now()
    scopes = service_scopes()

    Store.put_token(token, %{
      service: true,
      client_id: config.client.id <> "-svc",
      scope: scopes,
      issued_at: now,
      expires_at: now + Store.token_ttl()
    })

    %{
      access_token: token,
      token_type: "Bearer",
      expires_in: Store.token_ttl(),
      scope: Enum.join(scopes, " ")
    }
  end

  # The app record's service scopes; the default when no record exists yet.
  defp service_scopes do
    case Site.resolve(%{}) do
      {:ok, %{service_client: %{scopes: [_ | _] = scopes}}} -> scopes
      _other -> @default_service_scopes
    end
  rescue
    _error -> @default_service_scopes
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end
end
