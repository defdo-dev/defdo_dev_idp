defmodule Defdo.DevIdp.Flow do
  @moduledoc "Drives the authorize and token endpoints the way the client's PKCE plug does."

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.PKCE

  @verifier "dev-verifier-" <> String.duplicate("a", 40)
  @redirect_uri "http://localhost:4000/oauth2/defdo_auth"

  def verifier, do: @verifier
  def redirect_uri, do: @redirect_uri

  def params(overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => "dev-gateway",
        "redirect_uri" => @redirect_uri,
        "state" => "state-123",
        "code_challenge" => PKCE.challenge(@verifier),
        "code_challenge_method" => "S256",
        "scope" => "openid profile ai:admin"
      },
      overrides
    )
  end

  def authorize(overrides \\ %{}, opts \\ []) do
    Fixtures.get("/oauth/authorize", Keyword.merge([params: params(overrides)], opts))
  end

  def post_authorize(form) do
    Req.post!(Fixtures.url("/oauth/authorize"), form: form, retry: false, redirect: false)
  end

  def token(form, opts \\ []) do
    Req.post!(Fixtures.url("/oauth/token"), Keyword.merge([form: form, retry: false], opts))
  end

  def token_form(code, overrides \\ %{}) do
    Map.merge(
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => @verifier,
        "client_id" => "dev-gateway",
        "client_secret" => "dev-gateway-secret"
      },
      overrides
    )
  end

  def location(response) do
    [location] = Req.Response.get_header(response, "location")
    uri = URI.parse(location)
    {uri, URI.decode_query(uri.query || "")}
  end

  def code_for(profile, overrides \\ %{}) do
    response = authorize(Map.put(overrides, "profile", profile))
    {_uri, query} = location(response)
    Map.fetch!(query, "code")
  end

  def picker_token(html) do
    [_all, token] = Regex.run(~r/name="picker_token" value="([^"]+)"/, html)
    token
  end

  def codes_issued, do: :ets.info(:defdo_dev_idp_codes, :size)
end
