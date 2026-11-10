defmodule Defdo.DevIdp.Web.AuthorizeTokenTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.Flow

  setup do
    start_supervised!({Defdo.DevIdp, Fixtures.opts()})
    :ok
  end

  describe "the happy path" do
    test "authorize with profile=operator redirects with a code and the same state" do
      response = Flow.authorize(%{"profile" => "operator"})
      {uri, query} = Flow.location(response)

      assert response.status == 302
      assert "#{uri.scheme}://#{uri.host}:#{uri.port}#{uri.path}" == Flow.redirect_uri()
      assert query["state"] == "state-123"
      assert byte_size(query["code"]) >= 43
    end

    test "the legacy alias /openid/authorize behaves the same" do
      response =
        Fixtures.get("/openid/authorize", params: Flow.params(%{"profile" => "operator"}))

      assert response.status == 302
      assert {_uri, %{"code" => _code, "state" => "state-123"}} = Flow.location(response)
    end

    test "the token exchange returns the five keys and an id_token the JWKS verifies" do
      response =
        "operator" |> Flow.code_for(%{"nonce" => "nonce-1"}) |> Flow.token_form() |> Flow.token()

      assert response.status == 200

      assert response.body |> Map.keys() |> Enum.sort() ==
               ~w(access_token expires_in id_token scope token_type)

      assert response.body["token_type"] == "Bearer"
      assert response.body["expires_in"] == 3600
      assert response.body["scope"] == "openid profile ai:admin"

      %{"keys" => [key]} = Fixtures.get("/.well-known/jwks.json").body
      assert %{"kty" => "RSA", "use" => "sig", "alg" => "RS256", "kid" => kid} = key
      assert kid =~ ~r/\A[0-9a-f]{8}\z/
      refute Map.has_key?(key, "d")

      assert {true, %JOSE.JWT{fields: claims}, jws} =
               JOSE.JWT.verify_strict(
                 JOSE.JWK.from_map(key),
                 ["RS256"],
                 response.body["id_token"]
               )

      assert %JOSE.JWS{fields: %{"kid" => ^kid}} = jws
      assert claims["sub"] == "dev-operator-dev-tenant"
      assert claims["aud"] == "dev-gateway"
      assert claims["iss"] == "http://localhost:#{Defdo.DevIdp.port()}"
      assert claims["nonce"] == "nonce-1"
      assert claims["tenant_id"] == "00000000-0000-4000-8000-000000000001"
      assert claims["roles"] == ["operator"]
      assert claims["exp"] - claims["iat"] == 3600
    end

    test "an id_token carries no nonce when none was sent" do
      response = "operator" |> Flow.code_for() |> Flow.token_form() |> Flow.token()
      %{"keys" => [key]} = Fixtures.get("/.well-known/jwks.json").body

      {true, %JOSE.JWT{fields: claims}, _jws} =
        JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], response.body["id_token"])

      refute Map.has_key?(claims, "nonce")
    end
  end

  describe "the token endpoint refuses" do
    test "a wrong verifier" do
      form =
        Flow.token_form(Flow.code_for("operator"), %{"code_verifier" => String.duplicate("b", 50)})

      response = Flow.token(form)

      assert response.status == 400
      assert response.body == %{"error" => "invalid_grant"}
    end

    test "a missing verifier" do
      form = "operator" |> Flow.code_for() |> Flow.token_form() |> Map.delete("code_verifier")
      assert %{status: 400, body: %{"error" => "invalid_grant"}} = Flow.token(form)
    end

    test "a code used twice" do
      form = Flow.token_form(Flow.code_for("operator"))

      assert Flow.token(form).status == 200
      assert %{status: 400, body: %{"error" => "invalid_grant"}} = Flow.token(form)
    end

    test "a wrong verifier burns the code" do
      code = Flow.code_for("operator")

      assert Flow.token(Flow.token_form(code, %{"code_verifier" => "wrong"})).status == 400

      assert %{status: 400, body: %{"error" => "invalid_grant"}} =
               Flow.token(Flow.token_form(code))
    end

    test "a redirect_uri that differs from the authorize request" do
      form =
        Flow.token_form(Flow.code_for("operator"), %{
          "redirect_uri" => "http://localhost:4000/other"
        })

      assert %{status: 400, body: %{"error" => "invalid_grant"}} = Flow.token(form)
    end

    test "a wrong client secret, in the body or as Basic" do
      form = Flow.token_form(Flow.code_for("operator"), %{"client_secret" => "nope"})
      assert %{status: 401, body: %{"error" => "invalid_client"}} = Flow.token(form)

      basic =
        Flow.token_form(Flow.code_for("operator")) |> Map.drop(["client_id", "client_secret"])

      response = Flow.token(basic, auth: {:basic, "dev-gateway:nope"})
      assert %{status: 401, body: %{"error" => "invalid_client"}} = response
    end

    test "another grant type" do
      form = Flow.token_form(Flow.code_for("operator"), %{"grant_type" => "client_credentials"})
      assert %{status: 400, body: %{"error" => "unsupported_grant_type"}} = Flow.token(form)
    end
  end

  test "Basic client authentication is accepted" do
    form = Flow.token_form(Flow.code_for("operator")) |> Map.drop(["client_id", "client_secret"])
    response = Flow.token(form, auth: {:basic, "dev-gateway:dev-gateway-secret"})

    assert response.status == 200
    assert is_binary(response.body["access_token"])
  end

  describe "authorize refuses a client bug with a JSON 400 and no redirect" do
    for {name, change, error} <- [
          {"an unknown client_id", %{"client_id" => "other"}, "invalid_client"},
          {"a response_type other than code", %{"response_type" => "token"},
           "unsupported_response_type"},
          {"a redirect_uri outside localhost", %{"redirect_uri" => "http://evil.test/cb"},
           "invalid_request"},
          {"an https redirect_uri", %{"redirect_uri" => "https://localhost:4000/cb"},
           "invalid_request"},
          {"a redirect_uri with userinfo", %{"redirect_uri" => "http://localhost@evil.test/cb"},
           "invalid_request"},
          {"a missing code_challenge", %{"code_challenge" => ""}, "invalid_request"},
          {"the plain challenge method", %{"code_challenge_method" => "plain"},
           "invalid_request"},
          {"a missing state", %{"state" => ""}, "invalid_request"},
          {"an unknown profile", %{"profile" => "root"}, "invalid_request"}
        ] do
      test name do
        response =
          Flow.authorize(Map.put_new(unquote(Macro.escape(change)), "profile", "operator"))

        assert response.status == 400
        assert response.body["error"] == unquote(error)
        assert Req.Response.get_header(response, "location") == []
        assert Flow.codes_issued() == 0
      end
    end

    test "a missing code_challenge_method" do
      params = Flow.params(%{"profile" => "operator"}) |> Map.delete("code_challenge_method")
      response = Fixtures.get("/oauth/authorize", params: params)

      assert %{status: 400, body: %{"error" => "invalid_request"}} = response
      assert Flow.codes_issued() == 0
    end
  end

  test "prompt=none without a dev session answers login_required with the state" do
    response = Flow.authorize(%{"prompt" => "none"})
    {uri, query} = Flow.location(response)

    assert response.status == 302
    assert uri.host == "localhost"
    assert query == %{"error" => "login_required", "state" => "state-123"}
    assert Flow.codes_issued() == 0
  end

  test "scope narrowing: a profile never gets a scope it does not have" do
    response = "customer" |> Flow.code_for() |> Flow.token_form() |> Flow.token()
    assert response.body["scope"] == "openid profile"
  end

  describe "the picker" do
    test "renders one form per profile and says it is not a real login" do
      response = Flow.authorize()

      assert response.status == 200
      assert length(String.split(response.body, "<form ")) - 1 == 2
      assert response.body =~ "Sign in to :defdo_gateway"
      assert response.body =~ "Dev IdP — not a real login"
      assert response.body =~ ~s(name="state" value="state-123")
    end

    test "escapes every value, including the request's" do
      stop_supervised!(Defdo.DevIdp)

      hostile = %{
        key: :hostile,
        label: "<b>x</b>",
        role: "operator",
        tenant: "dev-tenant",
        scopes: ["openid"]
      }

      start_supervised!({Defdo.DevIdp, Fixtures.opts(profiles: [hostile])})

      body = Flow.authorize(%{"state" => ~s|"><script>alert(1)</script>|}).body

      refute body =~ "<b>x</b>"
      assert body =~ "&lt;b&gt;x&lt;/b&gt;"
      refute body =~ "<script>"
    end

    test "a submit with the page's token issues a code and opens a dev session" do
      token = Flow.picker_token(Flow.authorize().body)

      response =
        Flow.post_authorize(
          Map.merge(Flow.params(), %{"picker_token" => token, "profile" => "operator"})
        )

      assert response.status == 302
      assert {_uri, %{"code" => code, "state" => "state-123"}} = Flow.location(response)
      assert Flow.token(Flow.token_form(code)).status == 200

      [cookie] = Req.Response.get_header(response, "set-cookie")
      assert cookie =~ "_defdo_dev_idp="
      assert cookie =~ "HttpOnly"
      assert cookie =~ "SameSite=Lax"
      assert cookie =~ "max-age=28800"

      [pair | _attributes] = String.split(cookie, ";")
      silent = Flow.authorize(%{"prompt" => "none"}, headers: [cookie: pair])

      assert silent.status == 302
      assert {_uri, %{"code" => _code}} = Flow.location(silent)
    end

    test "a submit without picker_token is refused and issues no code" do
      response = Flow.post_authorize(Map.put(Flow.params(), "profile", "operator"))

      assert %{status: 400, body: %{"error" => "invalid_request"}} = response
      assert Req.Response.get_header(response, "set-cookie") == []
      assert Flow.codes_issued() == 0
    end

    test "a submit with a token issued for another state is refused and issues no code" do
      token = Flow.picker_token(Flow.authorize(%{"state" => "other-state"}).body)

      response =
        Flow.post_authorize(
          Map.merge(Flow.params(), %{"picker_token" => token, "profile" => "operator"})
        )

      assert %{status: 400, body: %{"error" => "invalid_request"}} = response
      assert Flow.codes_issued() == 0
    end

    test "a submit without a profile is refused" do
      token = Flow.picker_token(Flow.authorize().body)
      response = Flow.post_authorize(Map.put(Flow.params(), "picker_token", token))

      assert %{status: 400, body: %{"error" => "invalid_request"}} = response
      assert Flow.codes_issued() == 0
    end
  end
end
