defmodule Defdo.DevIdp.Web.ClientAuth do
  @moduledoc """
  Authenticates a dev client on the token and introspection endpoints:
  `client_id` + `client_secret` in the body, or HTTP Basic.

  There are two clients: the login client from the config, and the dev service
  client derived from it (`<id>-svc` / `<secret>-svc`).
  """

  import Plug.Conn

  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.SeedRunner

  @doc "Which client the request authenticates as."
  @spec identify(Plug.Conn.t(), Config.t()) :: {:ok, :login | :service} | :error
  def identify(conn, %Config{client: login} = config) do
    {id, secret} = credentials(conn)
    service = SeedRunner.service_client(config)

    cond do
      matches?(id, secret, login) -> {:ok, :login}
      matches?(id, secret, service) -> {:ok, :service}
      true -> :error
    end
  end

  @doc "True for either dev client."
  @spec check(Plug.Conn.t(), Config.t()) :: :ok | :error
  def check(conn, %Config{} = config) do
    case identify(conn, config) do
      {:ok, _client} -> :ok
      :error -> :error
    end
  end

  defp matches?(id, secret, client) do
    secure_equal?(id, client.id) and secure_equal?(secret, client.secret)
  end

  defp credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded | _rest] -> basic(encoded)
      _none -> {conn.params["client_id"], conn.params["client_secret"]}
    end
  end

  defp basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      {URI.decode_www_form(id), URI.decode_www_form(secret)}
    else
      _malformed -> {nil, nil}
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false
end
