defmodule Defdo.DevIdp.Web.ClientAuth do
  @moduledoc """
  Authenticates the dev client on the token and introspection endpoints:
  `client_id` + `client_secret` in the body, or HTTP Basic.
  """

  import Plug.Conn

  alias Defdo.DevIdp.Config

  @spec check(Plug.Conn.t(), Config.t()) :: :ok | :error
  def check(conn, %Config{client: client}) do
    {id, secret} = credentials(conn)

    if secure_equal?(id, client.id) and secure_equal?(secret, client.secret),
      do: :ok,
      else: :error
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
