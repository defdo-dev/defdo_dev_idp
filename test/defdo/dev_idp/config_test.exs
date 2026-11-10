defmodule Defdo.DevIdp.ConfigTest do
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.BootError
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Fixtures

  test "without a config block the child is ignored" do
    assert Application.get_all_env(:defdo_dev_idp) == []
    assert Defdo.DevIdp.start_link() == :ignore
    assert Config.fetch() == {:error, :disabled}
  end

  test "enabled: false is ignored even when the rest of the block is complete" do
    assert Defdo.DevIdp.start_link(Fixtures.opts(enabled: false)) == :ignore
    assert Process.whereis(Defdo.DevIdp) == nil
  end

  test "an enabled block with missing keys refuses to start and names the block and the host" do
    opts = [enabled: true, host: :defdo_gateway, port: 0]

    error = assert_raise BootError, fn -> Defdo.DevIdp.start_link(opts) end

    assert Exception.message(error) =~ "config :defdo_dev_idp"
    assert Exception.message(error) =~ ":defdo_gateway"
    assert Exception.message(error) =~ ":profiles"
    assert {:missing_config, missing} = error.reason
    assert :client in missing and :redirect_uri in missing
    assert Process.whereis(Defdo.DevIdp) == nil
  end

  test "a complete block builds the config" do
    assert {:ok, %Config{host: :defdo_gateway, client: %{id: "dev-gateway"}} = config} =
             Config.fetch(Fixtures.opts())

    assert length(config.profiles) == 2
  end
end
