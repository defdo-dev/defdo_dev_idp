defmodule Defdo.DevIdp.Keys do
  @moduledoc """
  The dev IdP's signing material, generated at start and held in memory only.

    * one RSA key that signs id_tokens; `jwks/0` publishes its public half;
    * one random secret that binds the picker form to the request it was
      rendered for (`picker_token/1`).

  Nothing here is persisted, logged or configurable: a restart invalidates
  every id_token and every open picker page.
  """

  use GenServer

  @alg "RS256"

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The JWKS document: the public key with `kid`, `use` and `alg`."
  @spec jwks() :: map()
  def jwks, do: GenServer.call(__MODULE__, :jwks)

  @doc "Signs the claims as a compact RS256 JWT with the key's `kid` in the header."
  @spec sign_id_token(map()) :: String.t()
  def sign_id_token(claims) when is_map(claims), do: GenServer.call(__MODULE__, {:sign, claims})

  @doc """
  The token a picker form must carry: an HMAC over the `state`, `client_id` and
  `redirect_uri` the page was rendered for.
  """
  @spec picker_token(%{state: String.t(), client_id: String.t(), redirect_uri: String.t()}) ::
          String.t()
  def picker_token(%{state: state, client_id: client_id, redirect_uri: redirect_uri}) do
    GenServer.call(__MODULE__, {:picker_token, [state, client_id, redirect_uri]})
  end

  @spec valid_picker_token?(map(), term()) :: boolean()
  def valid_picker_token?(request, token) when is_binary(token) do
    Plug.Crypto.secure_compare(picker_token(request), token)
  end

  def valid_picker_token?(_request, _token), do: false

  @impl GenServer
  def init(:ok) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_kty, public} = JOSE.JWK.to_public_map(jwk)

    {:ok,
     %{
       jwk: jwk,
       kid: kid(jwk),
       public: public,
       picker_secret: :crypto.strong_rand_bytes(32)
     }}
  end

  @impl GenServer
  def handle_call(:jwks, _from, state) do
    key = Map.merge(state.public, %{"kid" => state.kid, "use" => "sig", "alg" => @alg})
    {:reply, %{"keys" => [key]}, state}
  end

  def handle_call({:sign, claims}, _from, state) do
    header = %{"alg" => @alg, "kid" => state.kid, "typ" => "JWT"}
    {_jws, token} = state.jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    {:reply, token, state}
  end

  def handle_call({:picker_token, parts}, _from, state) do
    mac = :crypto.mac(:hmac, :sha256, state.picker_secret, Enum.join(parts, "\n"))
    {:reply, Base.url_encode64(mac, padding: false), state}
  end

  # 8 hex characters derived from the key's thumbprint.
  defp kid(jwk) do
    :sha256
    |> :crypto.hash(JOSE.JWK.thumbprint(jwk))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end
end
