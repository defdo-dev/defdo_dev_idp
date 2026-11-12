defmodule Defdo.DevIdp.Web.Router do
  @moduledoc """
  The dev IdP's HTTP surface.

  `LoopbackOnly` and `Unseeded` run before the route is matched: a non-loopback
  peer never learns which paths exist, and an unseeded server answers 503 on
  every page but the index.
  """

  use Plug.Router, copy_opts_to_assign: :config

  alias Defdo.DevIdp.Keys
  alias Defdo.DevIdp.State
  alias Defdo.DevIdp.Web.Authorize
  alias Defdo.DevIdp.Web.Discovery
  alias Defdo.DevIdp.Web.LoopbackOnly
  alias Defdo.DevIdp.Web.Pages
  alias Defdo.DevIdp.Web.Token
  alias Defdo.DevIdp.Web.Unseeded

  plug(LoopbackOnly)
  plug(Unseeded)
  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Pages.index(conn.assigns.config, State.get()))
  end

  get "/.well-known/openid-configuration" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Discovery.document(conn.assigns.config)))
  end

  get "/.well-known/jwks.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Keys.jwks()))
  end

  get("/oauth/authorize", do: Authorize.get(conn))
  # Legacy alias kept by defdo_auth; same handler.
  get("/openid/authorize", do: Authorize.get(conn))
  post("/oauth/authorize", do: Authorize.post(conn))
  post("/oauth/token", do: Token.post(conn))

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
