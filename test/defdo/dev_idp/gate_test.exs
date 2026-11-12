defmodule Defdo.DevIdp.GateTest do
  use ExUnit.Case, async: true

  alias Defdo.DevIdp.Gate

  @moduletag :tmp_dir

  defp touch(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  test "a release without the dev IdP passes", %{tmp_dir: dir} do
    touch(dir, "lib/other-1.0.0/ebin/Elixir.Other.beam")
    assert Gate.assert_absent!(dir) == :ok
  end

  test "a Defdo.DevIdp beam is refused, by name", %{tmp_dir: dir} do
    touch(dir, "lib/defdo_dev_idp-0.1.0/ebin/Elixir.Defdo.DevIdp.beam")

    assert_raise RuntimeError, ~r/\[beams\]/, fn -> Gate.assert_absent!(dir) end
  end

  test "a nested Defdo.DevIdp beam under another application is refused", %{tmp_dir: dir} do
    touch(dir, "lib/host-1.0.0/ebin/Elixir.Defdo.DevIdp.Web.Router.beam")

    assert_raise RuntimeError, ~r/\[beams\]/, fn -> Gate.assert_absent!(dir) end
  end

  test "the application directory alone is refused, by name", %{tmp_dir: dir} do
    touch(dir, "lib/defdo_dev_idp-0.1.0/priv/keep")

    assert_raise RuntimeError, ~r/\[app-dir\]/, fn -> Gate.assert_absent!(dir) end
  end

  test "a missing release directory is refused, never treated as clean", %{tmp_dir: dir} do
    assert_raise RuntimeError, ~r/\[release-dir\]/, fn ->
      Gate.assert_absent!(Path.join(dir, "nope"))
    end
  end

  test "a directory without lib/ is refused", %{tmp_dir: dir} do
    assert_raise RuntimeError, ~r/\[release-dir\]/, fn -> Gate.assert_absent!(dir) end
  end
end
