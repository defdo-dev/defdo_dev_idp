defmodule Defdo.DevIdp.Web.LoopbackOnlyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Defdo.DevIdp.Web.LoopbackOnly

  defp call(remote_ip) do
    :get
    |> conn("/")
    |> Map.put(:remote_ip, remote_ip)
    |> LoopbackOnly.call(LoopbackOnly.init([]))
  end

  test "a LAN peer gets 404 and the pipeline halts" do
    conn = call({10, 0, 0, 5})

    assert conn.halted
    assert conn.status == 404
  end

  test "a public IPv6 peer gets 404" do
    conn = call({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})

    assert conn.halted
    assert conn.status == 404
  end

  test "the three loopback spellings pass" do
    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 65_535, 32_512, 1}] do
      conn = call(ip)

      refute conn.halted
      assert conn.status == nil
    end
  end
end
