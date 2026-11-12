defmodule Defdo.DevIdp.Web.TokenClientCredentialsTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.Flow

  @service %{"client_id" => "dev-gateway-svc", "client_secret" => "dev-gateway-secret-svc"}

  setup do
    start_supervised!({Defdo.DevIdp, Fixtures.opts()})
    :ok
  end

  defp grant(form), do: Flow.token(Map.put(form, "grant_type", "client_credentials"))

  test "the service client mints a machine token with the service scopes" do
    response = grant(@service)

    assert response.status == 200

    assert response.body |> Map.keys() |> Enum.sort() ==
             ~w(access_token expires_in scope token_type)

    assert response.body["scope"] == "api:admin"
    assert response.body["expires_in"] == 3600
  end

  test "the machine token introspects as the service client on the pinned tenant" do
    token = grant(@service).body["access_token"]

    response =
      Req.post!(Fixtures.url("/api/v1/introspect"),
        json: %{token: token},
        headers: [{"x-internal-token", "dev-internal-token"}],
        retry: false
      )

    assert response.body["active"] == true
    assert response.body["sub"] == "dev-gateway-svc"
    assert response.body["client_id"] == "dev-gateway-svc"
    assert response.body["scopes"] == ["api:admin"]
    assert response.body["tenant_id"] == "00000000-0000-4000-8000-000000000001"
    refute Map.has_key?(response.body, "email")
  end

  test "a machine token has no userinfo" do
    token = grant(@service).body["access_token"]
    assert Fixtures.get("/openid/userinfo", auth: {:bearer, token}).status == 401
  end

  test "the login client asking for client_credentials is unauthorized_client" do
    response = grant(%{"client_id" => "dev-gateway", "client_secret" => "dev-gateway-secret"})

    assert response.status == 400
    assert response.body == %{"error" => "unauthorized_client"}
  end

  test "the service client cannot exchange an authorization code" do
    form = Map.merge(Flow.token_form(Flow.code_for("operator")), @service)

    assert %{status: 400, body: %{"error" => "unauthorized_client"}} = Flow.token(form)
  end

  test "a wrong service secret is invalid_client" do
    response = grant(%{@service | "client_secret" => "dev-gateway-secret"})

    assert response.status == 401
    assert response.body == %{"error" => "invalid_client"}
  end
end
