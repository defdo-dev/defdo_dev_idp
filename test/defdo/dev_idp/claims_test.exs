defmodule Defdo.DevIdp.ClaimsTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Claims
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.Store

  setup do
    start_supervised!(Store)
    %{config: Config.fetch!(Fixtures.opts())}
  end

  defp put_token(token, overrides \\ %{}) do
    Store.put_token(
      token,
      Map.merge(
        %{
          profile_key: :operator,
          client_id: "dev-gateway",
          scope: ["openid", "ai:admin"],
          issued_at: Store.now(),
          expires_at: Store.now() + 3600
        },
        overrides
      )
    )
  end

  test "the inactive answer is exactly the one-key map", %{config: config} do
    assert Claims.inactive() == %{"active" => false}
    assert Claims.introspect(config, "unknown") == %{"active" => false}
    assert Claims.introspect(config, nil) == %{"active" => false}
  end

  test "an expired token is inactive", %{config: config} do
    put_token("expired", %{expires_at: Store.now() - 1})
    assert Claims.introspect(config, "expired") == %{"active" => false}
  end

  test "a token whose profile is no longer configured is inactive", %{config: config} do
    put_token("orphan", %{profile_key: :removed})
    assert Claims.introspect(config, "orphan") == %{"active" => false}
  end

  test "an active token carries both scope spellings and all tenant spellings", %{config: config} do
    put_token("live")
    payload = Claims.introspect(config, "live")

    assert payload["active"] == true
    assert payload["sub"] == "dev-operator-dev-tenant"
    assert payload["scope"] == "openid ai:admin"
    assert payload["scopes"] == ["openid", "ai:admin"]
    assert payload["tenant"] == %{"id" => "00000000-0000-4000-8000-000000000001"}
    assert payload["tenant_id"] == "00000000-0000-4000-8000-000000000001"
    assert payload["client_id"] == "dev-gateway"
    assert payload["roles"] == ["operator"]
    assert payload["exp"] - payload["iat"] == 3600
  end
end
