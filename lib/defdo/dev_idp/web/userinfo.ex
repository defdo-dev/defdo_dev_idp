defmodule Defdo.DevIdp.Web.Userinfo do
  @moduledoc """
  `GET /openid/userinfo` with `Authorization: Bearer <token>`.

  The host callback only needs `sub`; the rest feeds host enrichment hooks.
  """

  import Plug.Conn

  alias Defdo.DevIdp.Claims

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    with {:ok, token} <- bearer(conn),
         {:ok, record, profile} <- Claims.lookup(conn.assigns.config, token) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode!(Claims.userinfo(record, profile)))
    else
      :error -> unauthorized(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] when token != "" -> {:ok, token}
      _missing -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
    |> send_resp(401, Jason.encode!(%{"error" => "invalid_token"}))
  end
end
