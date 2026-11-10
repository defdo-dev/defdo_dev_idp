defmodule Defdo.DevIdp.Web.Introspect do
  @moduledoc """
  The two introspection endpoints.

    * `POST /oauth/introspect` — the RFC 7662 shape the client adapter calls:
      form `token`, client authentication in the body or as Basic.
    * `POST /api/v1/introspect` — what credential introspection calls: JSON
      `{"token": ...}` and the header `x-internal-token`.

  An unknown or expired token is `200 {"active": false}` on both, never a 4xx.

  The client may also send `x-internal-*` HMAC headers. The dev IdP does NOT
  verify them: only the `x-internal-token` header is compared.
  """

  import Plug.Conn

  alias Defdo.DevIdp.Claims
  alias Defdo.DevIdp.Web.ClientAuth

  @spec oauth(Plug.Conn.t()) :: Plug.Conn.t()
  def oauth(conn) do
    config = conn.assigns.config

    case ClientAuth.check(conn, config) do
      :ok -> json(conn, 200, Claims.introspect(config, conn.params["token"]))
      :error -> json(conn, 401, %{"error" => "invalid_client"})
    end
  end

  @spec internal(Plug.Conn.t()) :: Plug.Conn.t()
  def internal(conn) do
    config = conn.assigns.config

    if internal_token?(conn, config.internal_api_token) do
      json(conn, 200, Claims.introspect(config, conn.params["token"]))
    else
      json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  defp internal_token?(conn, expected) do
    case get_req_header(conn, "x-internal-token") do
      [given] -> Plug.Crypto.secure_compare(given, expected)
      _missing_or_repeated -> false
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end
end
