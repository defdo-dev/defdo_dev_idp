defmodule Defdo.DevIdp.Web.Authorize do
  @moduledoc """
  `GET` and `POST /oauth/authorize` (and the legacy alias `GET /openid/authorize`).

  Both verbs validate through the same function. A request that fails
  validation is a client bug: it gets a JSON 400 and is never redirected, so an
  offending `redirect_uri` is never followed.

  After validation, `GET` issues a code for the `profile` param (headless), or
  for the dev session, or answers `error=login_required` to `prompt=none`, or
  renders the picker. `POST` is the picker's submit: it requires the
  `picker_token` rendered for this exact request.
  """

  import Plug.Conn

  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Keys
  alias Defdo.DevIdp.PKCE
  alias Defdo.DevIdp.Profile
  alias Defdo.DevIdp.Store
  alias Defdo.DevIdp.Web.Pages

  @cookie "_defdo_dev_idp"
  @cookie_max_age 8 * 60 * 60
  @loopback_hosts ["localhost", "127.0.0.1"]

  @type request :: %{
          client_id: String.t(),
          redirect_uri: String.t(),
          state: String.t(),
          code_challenge: String.t(),
          scope: String.t() | nil,
          nonce: String.t() | nil,
          prompt: String.t() | nil
        }

  @doc "The dev session cookie's name."
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    config = conn.assigns.config

    case validate(conn.params, config) do
      {:ok, request} -> respond_get(conn, config, request)
      {:error, code, description} -> client_error(conn, code, description)
    end
  end

  @spec post(Plug.Conn.t()) :: Plug.Conn.t()
  def post(conn) do
    config = conn.assigns.config

    with {:ok, request} <- validate(conn.params, config),
         :ok <- check_picker_token(request, conn.params["picker_token"]),
         {:ok, profile} <- fetch_profile(config, conn.params["profile"]) do
      sid = Store.random()
      Store.put_session(sid, profile.key)

      conn
      |> put_resp_cookie(@cookie, sid,
        http_only: true,
        same_site: "Lax",
        path: "/",
        max_age: @cookie_max_age
      )
      |> issue(request, profile)
    else
      {:error, code, description} -> client_error(conn, code, description)
    end
  end

  @doc "Validates the authorize parameters, in the order the slice fixes."
  @spec validate(map(), Config.t()) :: {:ok, request()} | {:error, String.t(), String.t()}
  def validate(params, %Config{} = config) do
    with :ok <- check_client(params, config),
         :ok <- check_response_type(params),
         :ok <- check_redirect_uri(params),
         :ok <- check_pkce(params),
         :ok <- check_state(params) do
      {:ok,
       %{
         client_id: params["client_id"],
         redirect_uri: params["redirect_uri"],
         state: params["state"],
         code_challenge: params["code_challenge"],
         scope: string(params["scope"]),
         nonce: string(params["nonce"]),
         prompt: string(params["prompt"])
       }}
    end
  end

  defp check_client(params, config) do
    if params["client_id"] == config.client.id,
      do: :ok,
      else: {:error, "invalid_client", "unknown client_id"}
  end

  defp check_response_type(params) do
    if params["response_type"] == "code",
      do: :ok,
      else: {:error, "unsupported_response_type", "response_type must be code"}
  end

  defp check_redirect_uri(params) do
    if loopback_uri?(params["redirect_uri"]),
      do: :ok,
      else: {:error, "invalid_request", "redirect_uri must be http on localhost or 127.0.0.1"}
  end

  defp loopback_uri?(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: "http", host: host, userinfo: nil}} -> host in @loopback_hosts
      _other -> false
    end
  end

  defp loopback_uri?(_uri), do: false

  defp check_pkce(params) do
    if present?(params["code_challenge"]) and params["code_challenge_method"] == PKCE.method(),
      do: :ok,
      else:
        {:error, "invalid_request", "code_challenge with code_challenge_method=S256 is required"}
  end

  defp check_state(params) do
    if present?(params["state"]), do: :ok, else: {:error, "invalid_request", "state is required"}
  end

  defp check_picker_token(request, token) do
    if Keys.valid_picker_token?(request, token),
      do: :ok,
      else:
        {:error, "invalid_request", "picker_token is missing or was issued for another request"}
  end

  defp respond_get(conn, config, request) do
    cond do
      present?(conn.params["profile"]) ->
        headless(conn, config, request)

      profile = session_profile(conn, config) ->
        issue(conn, request, profile)

      request.prompt == "none" ->
        redirect(conn, request.redirect_uri, error: "login_required", state: request.state)

      true ->
        picker(conn, config, request)
    end
  end

  defp headless(conn, config, request) do
    case fetch_profile(config, conn.params["profile"]) do
      {:ok, profile} -> issue(conn, request, profile)
      {:error, code, description} -> client_error(conn, code, description)
    end
  end

  defp picker(conn, config, request) do
    body = Pages.picker(config, request, Keys.picker_token(request))
    conn |> put_resp_content_type("text/html") |> send_resp(200, body)
  end

  defp session_profile(conn, config) do
    conn = fetch_cookies(conn)

    with {:ok, key} <- Store.get_session(conn.req_cookies[@cookie]),
         %Profile{} = profile <- Enum.find(config.profiles, &(&1.key == key)) do
      profile
    else
      _no_session -> nil
    end
  end

  # Matches the param against the configured keys as strings: a request never
  # creates an atom.
  defp fetch_profile(config, key) when is_binary(key) do
    case Enum.find(config.profiles, &(Atom.to_string(&1.key) == key)) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, "invalid_request", "unknown profile"}
    end
  end

  defp fetch_profile(_config, _key), do: {:error, "invalid_request", "profile is required"}

  defp issue(conn, request, profile) do
    code = Store.random()

    Store.put_code(code, %{
      profile_key: profile.key,
      client_id: request.client_id,
      redirect_uri: request.redirect_uri,
      code_challenge: request.code_challenge,
      scope: narrow(request.scope, profile.scopes),
      nonce: request.nonce,
      expires_at: Store.now() + Store.code_ttl()
    })

    redirect(conn, request.redirect_uri, code: code, state: request.state)
  end

  # The requested scopes the profile actually has, in the requested order. A
  # request without `scope` gets the profile's scopes.
  defp narrow(nil, profile_scopes), do: Enum.join(profile_scopes, " ")

  defp narrow(requested, profile_scopes) do
    requested
    |> String.split(" ", trim: true)
    |> Enum.filter(&(&1 in profile_scopes))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp redirect(conn, redirect_uri, query) do
    location =
      redirect_uri |> URI.new!() |> URI.append_query(URI.encode_query(query)) |> URI.to_string()

    conn
    |> put_resp_header("location", location)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(302, "")
  end

  defp client_error(conn, code, description) do
    body = Jason.encode!(%{error: code, error_description: description})
    conn |> put_resp_content_type("application/json") |> send_resp(400, body)
  end

  defp present?(value), do: is_binary(value) and value != ""
  defp string(value), do: if(present?(value), do: value)
end
