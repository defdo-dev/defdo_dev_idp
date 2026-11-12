defmodule Defdo.DevIdp.Integration.PkceLoginTest do
  @moduledoc """
  The dev IdP proven by its client: a fake host signs in through the real PKCE
  plug, reads the identity through the real `Identity`, and introspects the
  token through the real SDK. Only the picker submit is hand-built.
  """

  use ExUnit.Case, async: false

  alias Defdo.AuthClient.DevGuard
  alias Defdo.AuthClient.DevSiteError
  alias Defdo.AuthClient.SDK
  alias Defdo.AuthClient.Site
  alias Defdo.DevIdp.FakeHost
  alias Defdo.DevIdp.Fixtures

  @tenant_id "00000000-0000-4000-8000-000000000001"

  setup do
    start_supervised!({Defdo.DevIdp, Fixtures.opts()})
    host = start_supervised!({Bandit, plug: FakeHost, ip: {127, 0, 0, 1}, port: 0, scheme: :http})
    {:ok, {_ip, host_port}} = ThousandIsland.listener_info(host)

    idp = "http://localhost:#{Defdo.DevIdp.port()}"
    fake = "http://localhost:#{host_port}"
    previous = Application.get_env(:defdo_auth_client, Defdo.AuthClient)
    previous_record = Application.get_env(:defdo_auth_client, Defdo.AuthClient.Site)

    Application.put_env(:defdo_auth_client, Defdo.AuthClient,
      site: [vault_project: "test"],
      introspection: [internal_api_token: "dev-internal-token"]
    )

    # The app record where Defdo.Vault.Runtime writes it, mark included.
    Application.put_env(:defdo_auth_client, Defdo.AuthClient.Site,
      app_record: [
        site: idp,
        tenant: @tenant_id,
        connection: "dev-connection",
        client_id: "dev-gateway",
        client_secret: "dev-gateway-secret",
        redirect_uri: fake <> "/oauth2/defdo_auth",
        scopes: "openid profile ai:admin",
        idp_mark: "defdo-dev-idp"
      ]
    )

    on_exit(fn ->
      restore(Defdo.AuthClient, previous)
      restore(Defdo.AuthClient.Site, previous_record)
    end)

    %{idp: idp, fake: fake}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_auth_client, key)
  defp restore(key, value), do: Application.put_env(:defdo_auth_client, key, value)

  # ── a minimal cookie jar over Req ────────────────────────────────────────────

  defp request(method, url, jar, opts \\ []) do
    headers =
      if jar == %{},
        do: [],
        else: [cookie: Enum.map_join(jar, "; ", fn {k, v} -> "#{k}=#{v}" end)]

    opts =
      Keyword.merge(
        [method: method, url: url, headers: headers, retry: false, redirect: false],
        opts
      )

    response = Req.request!(opts)
    {response, collect(jar, response)}
  end

  defp collect(jar, response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.reduce(jar, fn cookie, jar ->
      [pair | _attributes] = String.split(cookie, ";")
      [name, value] = String.split(pair, "=", parts: 2)
      if value == "", do: Map.delete(jar, name), else: Map.put(jar, name, value)
    end)
  end

  defp location(response) do
    [location] = Req.Response.get_header(response, "location")
    location
  end

  defp query(url), do: URI.decode_query(URI.parse(url).query || "")

  defp hidden_fields(html, profile) do
    form =
      html
      |> String.split("<form ")
      |> Enum.find(&String.contains?(&1, ~s(name="profile" value="#{profile}")))

    ~r/<input type="hidden" name="([^"]+)" value="([^"]*)">/
    |> Regex.scan(form)
    |> Map.new(fn [_all, name, value] -> {name, unescape(value)} end)
  end

  defp unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp sign_in(%{idp: idp, fake: fake}) do
    {start, jar} = request(:get, fake <> "/oauth2/defdo_auth", %{})
    assert start.status == 302
    authorize_url = location(start)

    {picker, jar} = request(:get, authorize_url, jar)
    assert picker.status == 200

    {submitted, jar} =
      request(:post, idp <> "/oauth/authorize", jar, form: hidden_fields(picker.body, "operator"))

    assert submitted.status == 302
    callback_url = location(submitted)

    {callback, jar} = request(:get, callback_url, jar)
    {authorize_url, callback_url, callback, jar}
  end

  test "the real plug signs in through the dev IdP and the real Identity reads who it is", ctx do
    {authorize_url, callback_url, callback, jar} = sign_in(ctx)

    assert String.starts_with?(authorize_url, ctx.idp <> "/oauth/authorize?")
    sent = query(authorize_url)
    assert sent["code_challenge_method"] == "S256"
    assert sent["response_type"] == "code"
    assert sent["client_id"] == "dev-gateway"
    assert sent["redirect_uri"] == ctx.fake <> "/oauth2/defdo_auth"
    assert is_binary(sent["state"]) and sent["state"] != ""
    assert is_binary(sent["code_challenge"]) and sent["code_challenge"] != ""
    assert "ai:admin" in String.split(sent["scope"], " ")

    assert String.starts_with?(callback_url, ctx.fake <> "/oauth2/defdo_auth?")
    assert %{"code" => _code, "state" => state} = query(callback_url)
    assert state == sent["state"]

    assert callback.status in [302, 303]

    {whoami, _jar} = request(:get, ctx.fake <> "/whoami", jar)

    assert whoami.body["signed_in"] == true
    assert whoami.body["sub"] == "dev-operator-dev-tenant"
    assert whoami.body["tenant_id"] == @tenant_id
    assert whoami.body["roles"] == ["operator"]
    assert "ai:admin" in whoami.body["scopes"]
  end

  test "the SDK introspects the host's token the way a gateway does", ctx do
    {_authorize_url, _callback_url, _callback, jar} = sign_in(ctx)
    {whoami, _jar} = request(:get, ctx.fake <> "/whoami", jar)

    assert {:ok, payload} = SDK.introspect_credential(whoami.body["access_token"], %{})
    assert payload["active"] == true
    assert payload["tenant"] == %{"id" => @tenant_id}
    assert "ai:admin" in payload["scopes"]
  end

  describe "outside :dev and :test, the real client refuses this dev IdP by its mark" do
    setup do
      on_exit(fn -> Application.put_env(:defdo_auth_client, :env, :test) end)
      :ok
    end

    test "discovery, userinfo and the seeded-shape record are all refused", ctx do
      {_authorize_url, _callback_url, _callback, jar} = sign_in(ctx)
      {whoami, _jar} = request(:get, ctx.fake <> "/whoami", jar)
      {discovery, _jar} = request(:get, ctx.idp <> "/.well-known/openid-configuration", %{})

      {userinfo, _jar} =
        request(:get, ctx.idp <> "/openid/userinfo", %{},
          auth: {:bearer, whoami.body["access_token"]}
        )

      assert DevGuard.check_claims(userinfo.body) == :ok

      Application.put_env(:defdo_auth_client, :env, :prod)

      error =
        assert_raise DevSiteError, fn ->
          DevGuard.check_metadata!("https://idp.example.test", discovery.body)
        end

      assert error.mark == "discovery defdo_idp_mark"
      assert DevGuard.check_claims(userinfo.body) == {:error, {:dev_idp_mark, "defdo_idp_mark"}}
      assert_raise DevSiteError, fn -> Site.resolve(%{}) end
    end
  end

  test "a host without a session is not signed in", ctx do
    {whoami, _jar} = request(:get, ctx.fake <> "/whoami", %{})
    assert whoami.body["signed_in"] == false
  end

  test "after sign-out, prompt=none makes the plug retry interactively", ctx do
    {_authorize_url, _callback_url, _callback, jar} = sign_in(ctx)

    {cleared, jar} = request(:post, ctx.idp <> "/session/clear", jar)
    assert cleared.status == 303

    {start, jar} = request(:get, ctx.fake <> "/oauth2/defdo_auth?prompt=none", Map.take(jar, []))
    silent_url = location(start)
    assert query(silent_url)["prompt"] == "none"

    {refused, jar} = request(:get, silent_url, jar)
    assert refused.status == 302
    assert %{"error" => "login_required"} = query(location(refused))

    {retry, _jar} = request(:get, location(refused), jar)
    assert retry.status == 302
    retry_url = location(retry)

    assert String.starts_with?(retry_url, ctx.idp <> "/oauth/authorize?")
    refute Map.has_key?(query(retry_url), "prompt")
  end
end
