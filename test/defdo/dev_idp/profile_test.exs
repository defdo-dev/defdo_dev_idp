defmodule Defdo.DevIdp.ProfileTest do
  use ExUnit.Case, async: true

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.Profile

  test "derives sub, email and name" do
    [operator, _customer] = Profile.list!(Fixtures.profiles())

    assert operator.sub == "dev-operator-dev-tenant"
    assert operator.email == "operator@dev-tenant.dev.defdo"
    assert operator.name == "Operator · Defdo Red"
    assert operator.tenant_id == "00000000-0000-4000-8000-000000000001"
  end

  test "tenant_id defaults to the tenant" do
    [_operator, customer] = Profile.list!(Fixtures.profiles())
    assert customer.tenant_id == "acme"
  end

  test "refuses a role or tenant that is not a slug" do
    base = hd(Fixtures.profiles())

    assert_raise ArgumentError, ~r/:role/, fn ->
      Profile.new!(%{base | role: "Operator Admin"})
    end

    assert_raise ArgumentError, ~r/:tenant/, fn -> Profile.new!(%{base | tenant: "../etc"}) end
    assert_raise ArgumentError, ~r/:scopes/, fn -> Profile.new!(%{base | scopes: "openid"}) end
  end

  test "refuses duplicate keys and an empty list" do
    base = hd(Fixtures.profiles())

    assert_raise ArgumentError, ~r/unique/, fn -> Profile.list!([base, base]) end
    assert_raise ArgumentError, ~r/non-empty/, fn -> Profile.list!([]) end
  end
end
