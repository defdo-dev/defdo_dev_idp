defmodule Mix.Tasks.DefdoDevIdp.SeedTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DefdoDevIdp.Seed

  test "runs in dev and test" do
    assert Seed.ensure_env!(:dev) == :ok
    assert Seed.ensure_env!(:test) == :ok
  end

  test "refuses any other environment and says which" do
    for env <- [:prod, :stage, nil] do
      error = assert_raise Mix.Error, fn -> Seed.ensure_env!(env) end
      assert error.message =~ "runs only when"
      assert error.message =~ inspect(env)
    end
  end
end
