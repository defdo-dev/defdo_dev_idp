defmodule Defdo.DevIdp.Web.RouterTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.State
  alias Defdo.DevIdp.Web.Router

  defp start(overrides \\ []), do: start_supervised!({Defdo.DevIdp, Fixtures.opts(overrides)})

  test "the listener is bound to 127.0.0.1 on an OS-assigned port" do
    start()

    assert {:ok, {{127, 0, 0, 1}, port}} = Defdo.DevIdp.listener_info()
    assert port > 0
    assert Defdo.DevIdp.port() == port
  end

  test "the index shows the host, the state and the profiles" do
    start()
    response = Fixtures.get("/")

    assert response.status == 200
    assert response.body =~ "Dev IdP for :defdo_gateway"
    assert response.body =~ "<strong>ready</strong>"
    assert response.body =~ "dev-operator-dev-tenant"
    assert response.body =~ "Sign out everywhere"
  end

  test "the index escapes profile values" do
    hostile = %{
      key: :hostile,
      label: ~s|<script>alert("x")</script>|,
      role: "operator",
      tenant: "dev-tenant",
      scopes: ["openid"]
    }

    start(profiles: [hostile])
    body = Fixtures.get("/").body

    refute body =~ "<script>"
    assert body =~ "&lt;script&gt;"
  end

  test "discovery has the ten keys plus scopes_supported, on the bound port" do
    start()
    response = Fixtures.get("/.well-known/openid-configuration")
    issuer = "http://localhost:#{Defdo.DevIdp.port()}"

    assert response.status == 200

    assert response.body |> Map.keys() |> Enum.sort() == [
             "authorization_endpoint",
             "code_challenge_methods_supported",
             "defdo_idp_mark",
             "grant_types_supported",
             "introspection_endpoint",
             "issuer",
             "jwks_uri",
             "response_types_supported",
             "scopes_supported",
             "token_endpoint",
             "userinfo_endpoint"
           ]

    assert response.body["introspection_endpoint"] == issuer <> "/oauth/introspect"
    assert response.body["grant_types_supported"] == ["authorization_code"]
    refute "plain" in response.body["code_challenge_methods_supported"]
    assert response.body["defdo_idp_mark"] == "defdo-dev-idp"

    assert response.body["issuer"] == issuer
    assert response.body["authorization_endpoint"] == issuer <> "/oauth/authorize"
    assert response.body["code_challenge_methods_supported"] == ["S256"]
    assert response.body["scopes_supported"] == ["ai:admin", "openid", "profile"]
  end

  test "the router refuses a non-loopback peer on a page that exists" do
    start()
    config = State.config()
    opts = Router.init(config)

    local = Plug.Test.conn(:get, "/") |> Router.call(opts)
    assert local.status == 200

    remote =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> Router.call(opts)

    assert remote.status == 404
    assert remote.halted
  end

  test "an unknown path is 404" do
    start()
    assert Fixtures.get("/nope").status == 404
  end
end
