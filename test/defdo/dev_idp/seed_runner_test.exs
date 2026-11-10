defmodule Defdo.DevIdp.SeedRunnerTest do
  use Defdo.DevIdp.SeedCase, async: false

  alias Defdo.AuthClient.Site
  alias Defdo.AuthClient.Site.Codes
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.FakeConsumer
  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.SeedRunner
  alias Defdo.DevIdp.TestLog
  alias Defdo.Tenant.Provision.Step

  @operator "00000000-0000-4000-8000-000000000001"

  defp config(overrides \\ []) do
    Config.fetch!(
      Fixtures.opts(Keyword.merge([port: 4100, provision: [repo: NoRepo]], overrides))
    )
  end

  defp run(config \\ config()), do: SeedRunner.run(config, provision_opts: provision_opts())

  defp events_of(kind), do: Enum.filter(TestLog.events(), &(elem(&1, 0) == kind))
  defp events_except(kind), do: Enum.reject(TestLog.events(), &(elem(&1, 0) == kind))

  test "the first run provisions, writes and reports, in order" do
    assert {:ok, lines} = run()

    assert lines == [
             "tenant #{@operator}: provisioned",
             "tenant acme: provisioned",
             "app record: written",
             "site record acme: written",
             "dev idp: not running"
           ]

    events = TestLog.events()
    kinds = events |> Enum.map(&elem(&1, 0)) |> Enum.dedup()

    assert kinds == [:provision, :app_code, :customer_record]
    assert Enum.take(events, 2) == [{:provision, @operator}, {:provision, "acme"}]
  end

  test "the app record is written code by code under the credentials tenant" do
    assert {:ok, _lines} = run()

    app_codes = for {:app_code, key, tenant} <- TestLog.events(), do: {key, tenant}

    assert length(app_codes) == length(Codes.keys()) + 1
    assert Enum.all?(app_codes, fn {_key, tenant} -> tenant == vault_tenant() end)
    assert {"internal_api_token", vault_tenant()} in app_codes

    assert {:ok, client} = Site.resolve(%{})
    assert client.site == "http://localhost:4100"
    assert client.tenant == @operator
    assert client.connection == "dev-connection"
    assert client.client_id == "dev-gateway"
    assert client.scopes == ~w(openid profile ai:admin)
    assert client.service_client.client_id == "dev-gateway-svc"
    assert client.service_client.scopes == ["api:admin"]
  end

  test "a customer record is written inside that tenant's context, with that tenant's scopes" do
    assert {:ok, _lines} = run()

    assert events_of(:customer_record) == [{:customer_record, "acme"}]

    assert {:ok, client} = Site.resolve(%{tenant_id: "acme"})
    assert client.site == "http://localhost:4100"
    assert client.tenant == "acme"
    assert client.scopes == ~w(openid profile)
  end

  test "a second run changes nothing" do
    assert {:ok, _lines} = run()
    TestLog.clear()

    assert {:ok, lines} = run()

    assert lines == [
             "tenant #{@operator}: unchanged",
             "tenant acme: unchanged",
             "app record: unchanged",
             "site record acme: unchanged",
             "dev idp: not running"
           ]

    assert TestLog.events() == []
  end

  test "app_record_extra is merged into the records" do
    assert {:ok, _lines} = run(config(app_record_extra: %{"registration_type" => "staff"}))

    assert {:ok, %{registration_type: "staff"}} = Site.resolve(%{})
    assert {:ok, %{registration_type: "staff"}} = Site.resolve(%{tenant_id: "acme"})
  end

  test "an app record that points at another site is refused and left untouched" do
    put_app_record(
      site: "https://idp.example.test",
      tenant: "real-tenant",
      client_id: "real-client",
      connection: "real-connection",
      redirect_uri: "https://app.example.test/cb"
    )

    assert run() == {:error, {:foreign_app_record, "https://idp.example.test"}}
    assert events_except(:provision) == []

    assert {:ok, %{site: "https://idp.example.test", client_id: "real-client"}} =
             Site.resolve(%{})

    assert SeedRunner.format_error({:foreign_app_record, "https://idp.example.test"}) =~
             "refusing to overwrite"
  end

  test "a customer record that points at another site is refused and left untouched" do
    FakeConsumer.put_customer("acme", %{
      "site" => "https://idp.example.test",
      "tenant" => "acme",
      "client_id" => "real-client",
      "connection" => "real-connection",
      "redirect_uri" => "https://app.example.test/cb"
    })

    assert run() == {:error, {:foreign_site_record, "acme", "https://idp.example.test"}}
    assert events_of(:customer_record) == []
  end

  test "an app record for this dev IdP with another client is rewritten" do
    put_app_record(
      site: "http://localhost:4100",
      tenant: @operator,
      client_id: "stale-client",
      connection: "dev-connection",
      redirect_uri: "http://localhost:4000/oauth2/defdo_auth"
    )

    assert {:ok, lines} = run()
    assert "app record: written" in lines
    assert {:ok, %{client_id: "dev-gateway"}} = Site.resolve(%{})
  end

  test "without a provision repo the run stops before anything is written" do
    assert run(config(provision: [])) == {:error, {:no_provision_repo}}
    assert TestLog.events() == []
    assert SeedRunner.format_error({:no_provision_repo}) =~ "provision: [repo:"
  end

  test "a provisioning failure stops the run before any record is written" do
    boom = Step.new(:boom, :transactional, fn _ctx -> {:error, :boom} end)
    failing = Keyword.put(provision_opts(), :steps, [boom])

    assert {:error, {:provision_failed, @operator, _reason}} =
             SeedRunner.run(config(), provision_opts: failing)

    assert events_except(:provision) == []
  end

  test "error messages never include the failure's inner reason" do
    message = SeedRunner.format_error({:site_put_failed, :app, %{secret: "dev-gateway-secret"}})
    refute message =~ "dev-gateway-secret"
  end
end
