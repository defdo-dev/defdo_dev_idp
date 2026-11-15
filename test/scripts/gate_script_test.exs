defmodule Defdo.DevIdp.GateScriptTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/ci/assert-no-dev-idp.sh", __DIR__)

  defp run(args, opts \\ []) do
    System.cmd("sh", [@script | args], Keyword.merge([stderr_to_stdout: true], opts))
  end

  defp touch(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  test "the script is executable" do
    assert Bitwise.band(File.stat!(@script).mode, 0o111) != 0
  end

  test "release: a tree without the dev IdP passes", %{tmp_dir: dir} do
    touch(dir, "lib/other-1.0.0/ebin/Elixir.Other.beam")

    assert {output, 0} = run(["release", dir])
    assert output =~ "assert-no-dev-idp: ok"
  end

  test "release: a Defdo.DevIdp beam fails with [beams]", %{tmp_dir: dir} do
    touch(dir, "lib/defdo_dev_idp-0.1.0/ebin/Elixir.Defdo.DevIdp.beam")

    assert {output, 1} = run(["release", dir])
    assert output =~ "assert-no-dev-idp[beams]"
  end

  test "release: the application directory alone fails with [app-dir]", %{tmp_dir: dir} do
    touch(dir, "lib/defdo_dev_idp-0.1.0/priv/keep")

    assert {output, 1} = run(["release", dir])
    assert output =~ "assert-no-dev-idp[app-dir]"
  end

  test "release: a missing directory fails with [release-dir]", %{tmp_dir: dir} do
    assert {output, 1} = run(["release", Path.join(dir, "nope")])
    assert output =~ "assert-no-dev-idp[release-dir]"
  end

  test "deps: without mix on PATH the gate fails closed", %{tmp_dir: dir} do
    assert {output, 1} = run(["deps"], env: [{"PATH", "/usr/bin:/bin"}], cd: dir)
    assert output =~ "assert-no-dev-idp[deps-tree]: mix deps.tree failed"
  end

  test "an unknown mode is a usage error" do
    assert {output, 2} = run(["sideways"])
    assert output =~ "assert-no-dev-idp[usage]"
  end

  test "no mode is an error" do
    assert {_output, status} = run([])
    assert status != 0
  end
end
