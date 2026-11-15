defmodule Defdo.DevIdp.PKCETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Defdo.DevIdp.PKCE

  @unreserved Enum.concat([?A..?Z, ?a..?z, ?0..?9, ~c"-._~"])

  defp verifier do
    StreamData.string(@unreserved, min_length: 43, max_length: 128)
  end

  test "the challenge is the S256 transform the client computes" do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert PKCE.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    assert PKCE.method() == "S256"
  end

  test "a verifier or challenge that is not a string never verifies" do
    refute PKCE.verify(nil, "x")
    refute PKCE.verify("x", nil)
  end

  test "the challenge itself is not accepted as the verifier (plain is refused)" do
    verifier = String.duplicate("a", 43)
    challenge = PKCE.challenge(verifier)
    refute PKCE.verify(challenge, challenge)
  end

  property "a verifier verifies against its own challenge" do
    check all(v <- verifier()) do
      assert PKCE.verify(v, PKCE.challenge(v))
    end
  end

  property "a different verifier never verifies" do
    check all(v <- verifier(), v2 <- verifier(), v != v2) do
      refute PKCE.verify(v2, PKCE.challenge(v))
    end
  end
end
