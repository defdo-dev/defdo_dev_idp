defmodule Defdo.DevIdp.FreshDbTest do
  use Defdo.DevIdp.SeedCase, async: false

  alias Defdo.DevIdp.Fixtures
  alias Defdo.DevIdp.Flow
  alias Defdo.DevIdp.SeedRunner
  alias Defdo.DevIdp.State

  test "unseeded, then seeded, then ready: authorize is no longer 503" do
    opts = Fixtures.opts(provision: [repo: NoRepo]) |> Keyword.delete(:site_reader)
    start_supervised!({Defdo.DevIdp, opts})

    assert State.get() == :unseeded
    assert Flow.authorize(%{"profile" => "operator"}).status == 503

    assert {:ok, lines} = SeedRunner.run(State.config(), provision_opts: provision_opts())

    assert List.last(lines) == "dev idp: ready"
    assert State.get() == :ready
    assert Flow.authorize(%{"profile" => "operator"}).status == 302
  end
end
