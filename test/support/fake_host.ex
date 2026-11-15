defmodule Defdo.DevIdp.FakeHost do
  @moduledoc """
  A minimal host app: a cookie session, the REAL PKCE plug from defdo_auth_client
  at `/oauth2/defdo_auth`, and `/whoami`, which reads the REAL `Identity`.

  The plug gets no `resolve_client`: the client comes from the `Site` app record.
  """

  use Plug.Router

  alias Defdo.AuthClient.Identity
  alias Defdo.DefdoAuth.Plug.AuthorizeCodeWithPKCE

  plug(:put_secret_key_base)
  plug(Plug.Session, store: :cookie, key: "_fake_host", signing_salt: "fake-host-signing-salt")
  plug(:fetch_session)
  plug(:fetch_query_params)
  plug(:match)
  plug(:dispatch)

  get "/oauth2/defdo_auth" do
    opts = AuthorizeCodeWithPKCE.init(scopes: ~w(openid profile ai:admin), state_store: :session)
    conn |> AuthorizeCodeWithPKCE.call(opts) |> continue_after_login()
  end

  get "/whoami" do
    body =
      case Identity.from_conn(conn) do
        {:ok, identity} ->
          %{
            signed_in: true,
            sub: identity.sub,
            email: identity.email,
            tenant_id: identity.tenant_id,
            roles: identity.roles,
            scopes: identity.scopes,
            access_token: access_token(get_session(conn, :user_token))
          }

        {:error, reason} ->
          %{signed_in: false, reason: inspect(reason)}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # The plug caches the OAuth client under the session's user token; a host
  # reads the IdP access token from there to call APIs on the user's behalf.
  defp access_token(user_token) do
    case Cachex.get(:defdo_auth_user_client, user_token) do
      {:ok, %{token: %{access_token: access_token}}} -> access_token
      _missing -> nil
    end
  end

  # On a successful callback the plug leaves the conn unsent: the host's own
  # action runs next. This host sends the user home.
  defp continue_after_login(%Plug.Conn{halted: true} = conn), do: conn
  defp continue_after_login(%Plug.Conn{state: :sent} = conn), do: conn

  defp continue_after_login(conn) do
    conn |> put_resp_header("location", "/whoami") |> send_resp(302, "")
  end

  defp put_secret_key_base(conn, _opts) do
    %{conn | secret_key_base: String.duplicate("fake-host-secret-key-base-", 4)}
  end
end
