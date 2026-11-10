defmodule Defdo.DevIdp.Web.IntrospectUserinfoTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.Flow

  setup do
    start_supervised!({Defdo.DevIdp, Fixtures.opts()})
    token = "operator" |> Flow.code_for() |> Flow.token_form() |> Flow.token()
    %{token: token.body["access_token"]}
  end

  defp post(path, opts),
    do: Req.post!(Fixtures.url(path), Keyword.merge([retry: false, redirect: false], opts))

  defp client(form) do
    Map.merge(%{"client_id" => "dev-gateway", "client_secret" => "dev-gateway-secret"}, form)
  end

  describe "POST /oauth/introspect" do
    test "an active token answers the claims", %{token: token} do
      response = post("/oauth/introspect", form: client(%{"token" => token}))

      assert response.status == 200
      assert response.body["active"] == true
      assert response.body["scope"] == "openid profile ai:admin"
      assert response.body["defdo_idp_mark"] == "defdo-dev-idp"
      assert response.body["scopes"] == ["openid", "profile", "ai:admin"]
      assert response.body["tenant"]["id"] == "00000000-0000-4000-8000-000000000001"
      assert response.body["sub"] == "dev-operator-dev-tenant"
    end

    test "Basic client authentication is accepted", %{token: token} do
      response =
        post("/oauth/introspect",
          form: %{"token" => token},
          auth: {:basic, "dev-gateway:dev-gateway-secret"}
        )

      assert response.body["active"] == true
    end

    test "an unknown token is 200 with exactly the inactive answer" do
      response = post("/oauth/introspect", form: client(%{"token" => "unknown"}))

      assert response.status == 200
      assert response.body == %{"active" => false}
    end

    test "a missing token is the inactive answer" do
      assert post("/oauth/introspect", form: client(%{})).body == %{"active" => false}
    end

    test "a wrong client is 401 and says nothing about the token", %{token: token} do
      response =
        post("/oauth/introspect", form: client(%{"token" => token, "client_secret" => "nope"}))

      assert response.status == 401
      assert response.body == %{"error" => "invalid_client"}
    end
  end

  describe "POST /api/v1/introspect" do
    test "the right header answers the claims", %{token: token} do
      response =
        post("/api/v1/introspect",
          json: %{token: token},
          headers: [{"x-internal-token", "dev-internal-token"}]
        )

      assert response.status == 200
      assert response.body["active"] == true
      assert response.body["scopes"] == ["openid", "profile", "ai:admin"]
      assert response.body["defdo_idp_mark"] == "defdo-dev-idp"
      assert response.body["tenant_id"] == "00000000-0000-4000-8000-000000000001"
      assert response.body["client_id"] == "dev-gateway"
    end

    test "token_type_hint and HMAC headers are ignored", %{token: token} do
      response =
        post("/api/v1/introspect",
          json: %{token: token, token_type_hint: "access_token"},
          headers: [
            {"x-internal-token", "dev-internal-token"},
            {"x-internal-signature", "not-verified"},
            {"x-internal-timestamp", "0"}
          ]
        )

      assert response.status == 200
      assert response.body["active"] == true
    end

    test "a missing header is 401 and the body has no sub", %{token: token} do
      response = post("/api/v1/introspect", json: %{token: token})

      assert response.status == 401
      assert response.body == %{"error" => "unauthorized"}
      refute Map.has_key?(response.body, "sub")
    end

    test "a wrong header is 401", %{token: token} do
      response =
        post("/api/v1/introspect", json: %{token: token}, headers: [{"x-internal-token", "nope"}])

      assert response.status == 401
      refute Map.has_key?(response.body, "sub")
    end

    test "an unknown token is 200 with exactly the inactive answer" do
      response =
        post("/api/v1/introspect",
          json: %{token: "unknown"},
          headers: [{"x-internal-token", "dev-internal-token"}]
        )

      assert response.status == 200
      assert response.body == %{"active" => false}
    end
  end

  describe "GET /openid/userinfo" do
    test "a Bearer token answers the profile", %{token: token} do
      response = Fixtures.get("/openid/userinfo", auth: {:bearer, token})

      assert response.status == 200

      assert response.body == %{
               "sub" => "dev-operator-dev-tenant",
               "email" => "operator@dev-tenant.dev.defdo",
               "email_verified" => true,
               "name" => "Operator · Defdo Red",
               "preferred_username" => "operator@dev-tenant.dev.defdo",
               "tenant_id" => "00000000-0000-4000-8000-000000000001",
               "roles" => ["operator"],
               "scope" => "openid profile ai:admin",
               "defdo_idp_mark" => "defdo-dev-idp"
             }
    end

    test "no header is 401 with WWW-Authenticate" do
      response = Fixtures.get("/openid/userinfo")

      assert response.status == 401
      assert response.body == %{"error" => "invalid_token"}

      assert Req.Response.get_header(response, "www-authenticate") == [
               ~s(Bearer error="invalid_token")
             ]
    end

    test "an unknown token is 401" do
      response = Fixtures.get("/openid/userinfo", auth: {:bearer, "unknown"})

      assert response.status == 401
      refute Map.has_key?(response.body, "sub")
    end
  end

  describe "POST /session/clear" do
    defp sign_in do
      token = Flow.picker_token(Flow.authorize().body)

      response =
        Flow.post_authorize(
          Map.merge(Flow.params(), %{"picker_token" => token, "profile" => "operator"})
        )

      [cookie] = Req.Response.get_header(response, "set-cookie")
      cookie |> String.split(";") |> hd()
    end

    test "the next prompt=none answers login_required" do
      cookie = sign_in()

      assert {_uri, %{"code" => _code}} =
               Flow.location(Flow.authorize(%{"prompt" => "none"}, headers: [cookie: cookie]))

      response = post("/session/clear", headers: [cookie: cookie])

      assert response.status == 303
      assert Req.Response.get_header(response, "location") == ["/"]
      [expired] = Req.Response.get_header(response, "set-cookie")
      assert expired =~ "_defdo_dev_idp=;"
      assert expired =~ "max-age=0"

      after_clear = Flow.authorize(%{"prompt" => "none"}, headers: [cookie: cookie])

      assert {_uri, %{"error" => "login_required", "state" => "state-123"}} =
               Flow.location(after_clear)
    end

    test "the index shows who is signed in, then no dev session" do
      cookie = sign_in()

      assert Fixtures.get("/", headers: [cookie: cookie]).body =~
               "Signed in as Operator · Defdo Red."

      post("/session/clear", headers: [cookie: cookie])

      body = Fixtures.get("/", headers: [cookie: cookie]).body
      assert body =~ "No dev session."
      assert body =~ "does not revoke tokens"
    end

    test "tokens are not revoked", %{token: token} do
      post("/session/clear", [])
      assert Fixtures.get("/openid/userinfo", auth: {:bearer, token}).status == 200
    end
  end
end
