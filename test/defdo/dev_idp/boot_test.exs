defmodule Defdo.DevIdp.BootTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.Boot
  alias Defdo.DevIdp.BootError
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Fixtures

  defp config(overrides), do: Config.fetch!(Fixtures.opts(overrides))
  defp reader(sites), do: fn _tenant_ids -> sites end

  describe "check/1 with a reader" do
    test "a site that points elsewhere is a mismatch" do
      remote = "https://idp.example.test"

      assert {:error, {:site_mismatch, [^remote], "http://localhost:4100"}} =
               Boot.check(config(port: 4100, site_reader: reader([remote])))
    end

    test "one remote site among local ones is still a mismatch" do
      sites = ["http://localhost:4100", "https://idp.example.test"]

      assert {:error, {:site_mismatch, ["https://idp.example.test"], _expected}} =
               Boot.check(config(port: 4100, site_reader: reader(sites)))
    end

    test "sites that are this dev IdP are ready, in either loopback spelling" do
      sites = ["http://localhost:4100/", "HTTP://127.0.0.1:4100"]
      assert Boot.check(config(port: 4100, site_reader: reader(sites))) == {:ok, :ready}
    end

    test "the same host on another port is a mismatch" do
      assert {:error, {:site_mismatch, _remote, _expected}} =
               Boot.check(config(port: 4100, site_reader: reader(["http://localhost:4101"])))
    end

    test "no site at all is unseeded" do
      assert Boot.check(config(site_reader: reader([]))) == {:ok, :unseeded}
    end

    test "a reader that raises is a lookup failure naming the exception" do
      failing = fn _tenant_ids -> raise RuntimeError, "repo is not started" end

      assert Boot.check(config(site_reader: failing)) ==
               {:error, {:site_lookup_failed, RuntimeError}}
    end

    test "the reader receives the unique tenant ids of the profiles" do
      parent = self()

      capture = fn tenant_ids ->
        send(parent, {:tenant_ids, tenant_ids})
        []
      end

      Boot.check(config(site_reader: capture))

      assert_received {:tenant_ids, ["00000000-0000-4000-8000-000000000001", "acme"]}
    end
  end

  describe "check/1 against Defdo.AuthClient.Site (the app record as the vault Runtime writes it)" do
    # `site:` config may only name the vault project; the record itself lives
    # where the vault Runtime writes it.
    setup do
      config = Application.get_env(:defdo_auth_client, Defdo.AuthClient)
      record = Application.get_env(:defdo_auth_client, Defdo.AuthClient.Site)

      on_exit(fn ->
        restore(Defdo.AuthClient, config)
        restore(Defdo.AuthClient.Site, record)
      end)

      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:defdo_auth_client, key)
    defp restore(key, value), do: Application.put_env(:defdo_auth_client, key, value)

    defp put_app_record(site) do
      Application.put_env(:defdo_auth_client, Defdo.AuthClient,
        site: [vault_project: "dev_idp_test"]
      )

      Application.put_env(:defdo_auth_client, Defdo.AuthClient.Site,
        app_record: [
          site: site,
          tenant: "00000000-0000-4000-8000-000000000001",
          connection: "dev-connection",
          client_id: "dev-gateway",
          client_secret: "dev-gateway-secret",
          redirect_uri: "http://localhost:4000/oauth2/defdo_auth",
          scopes: "openid profile"
        ]
      )
    end

    test "a remote app site is a mismatch" do
      put_app_record("https://idp.example.test")

      assert {:error, {:site_mismatch, ["https://idp.example.test"], _expected}} =
               Boot.check(config(port: 4100, site_reader: nil))
    end

    test "an app site that is this dev IdP is ready" do
      put_app_record("http://localhost:4100")
      assert Boot.check(config(port: 4100, site_reader: nil)) == {:ok, :ready}
    end

    test "no app record is unseeded" do
      Application.delete_env(:defdo_auth_client, Defdo.AuthClient)
      Application.delete_env(:defdo_auth_client, Defdo.AuthClient.Site)
      assert Boot.check(config(site_reader: nil)) == {:ok, :unseeded}
    end
  end

  describe "start_link/1" do
    test "a mismatch raises BootError and leaves no process" do
      opts = Fixtures.opts(port: 4100, site_reader: reader(["https://idp.example.test"]))

      error = assert_raise BootError, fn -> Defdo.DevIdp.start_link(opts) end

      assert Exception.message(error) =~ "https://idp.example.test"
      assert Exception.message(error) =~ "never reach a real IdP"
      assert Process.whereis(Defdo.DevIdp) == nil
      assert Process.whereis(Defdo.DevIdp.State) == nil
    end

    test "a lookup failure raises BootError that names the fix" do
      failing = fn _tenant_ids -> raise RuntimeError, "repo is not started" end

      error =
        assert_raise BootError, fn ->
          Defdo.DevIdp.start_link(Fixtures.opts(site_reader: failing))
        end

      assert error.reason == {:site_lookup_failed, RuntimeError}
      assert Exception.message(error) =~ "after your Repo"
      assert Process.whereis(Defdo.DevIdp) == nil
    end
  end
end
