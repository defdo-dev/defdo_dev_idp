defmodule Defdo.DevIdp.PKCE do
  @moduledoc """
  PKCE, method S256 only.

  The challenge is byte-for-byte what `Defdo.DefdoAuth.Strategy.AuthCodePKCE`
  computes. `plain` is never accepted: a request that names it, or names no
  method, is refused before a code is issued.
  """

  @method "S256"

  @doc "The only accepted `code_challenge_method`."
  @spec method() :: String.t()
  def method, do: @method

  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier) do
    :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  @spec verify(verifier :: term(), challenge :: term()) :: boolean()
  def verify(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    Plug.Crypto.secure_compare(challenge(verifier), challenge)
  end

  def verify(_verifier, _challenge), do: false
end
