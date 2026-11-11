defmodule Defdo.DevIdp.UnseededTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.State

  setup do
    {:ok, sites} = Agent.start_link(fn -> [] end)
    reader = fn _tenant_ids -> Agent.get(sites, & &1) end
    start_supervised!({Defdo.DevIdp, Fixtures.opts(site_reader: reader)})
    %{sites: sites}
  end

  test "an unseeded server answers 503 with the seed command on every page but the index" do
    assert State.get() == :unseeded

    response = Fixtures.get("/oauth/authorize?client_id=dev-gateway")
    assert response.status == 503
    assert response.body =~ "mix defdo_dev_idp.seed"
    assert response.body =~ ":defdo_gateway"

    discovery = Fixtures.get("/.well-known/openid-configuration")
    assert discovery.status == 503
  end

  test "the 503 is JSON when the client asks for JSON" do
    response = Fixtures.get("/oauth/token", headers: [accept: "application/json"])

    assert response.status == 503
    assert %{"error" => "unseeded", "error_description" => text} = response.body
    assert text =~ "mix defdo_dev_idp.seed"
  end

  test "the index is exempt and shows the state" do
    response = Fixtures.get("/")

    assert response.status == 200
    assert response.body =~ "unseeded"
    assert response.body =~ "mix defdo_dev_idp.seed"
  end

  test "a request re-checks, so the server recovers once the record exists", %{sites: sites} do
    assert Fixtures.get("/.well-known/openid-configuration").status == 503

    Agent.update(sites, fn _ -> ["http://localhost:0"] end)

    assert Fixtures.get("/.well-known/openid-configuration").status == 200
    assert State.get() == :ready
  end

  test "recheck/0 flips the state without a request", %{sites: sites} do
    assert Defdo.DevIdp.recheck() == {:ok, :unseeded}

    Agent.update(sites, fn _ -> ["http://localhost:0"] end)

    assert Defdo.DevIdp.recheck() == {:ok, :ready}
    assert State.get() == :ready
  end

  test "recheck/0 reports a mismatch and keeps the state", %{sites: sites} do
    Agent.update(sites, fn _ -> ["https://idp.example.test"] end)

    assert {:error, {:site_mismatch, _remote, _expected}} = Defdo.DevIdp.recheck()
    assert State.get() == :unseeded
    assert Fixtures.get("/.well-known/openid-configuration").status == 503
  end
end
