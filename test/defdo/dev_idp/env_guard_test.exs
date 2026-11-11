defmodule Defdo.DevIdp.EnvGuardTest do
  # Mutates the :defdo_auth_client application env, so it cannot run async.
  use ExUnit.Case, async: false

  alias Defdo.DevIdp.BootError
  alias Defdo.DevIdp.Fixtures

  setup do
    previous = Application.fetch_env(:defdo_auth_client, :env)

    on_exit(fn ->
      case previous do
        {:ok, env} -> Application.put_env(:defdo_auth_client, :env, env)
        :error -> Application.delete_env(:defdo_auth_client, :env)
      end
    end)

    :ok
  end

  defp refused_without_supervisor(opts \\ Fixtures.opts()) do
    case start(opts) do
      {:refused, error} ->
        refute Process.whereis(Defdo.DevIdp)
        error

      {:started, pid} ->
        Supervisor.stop(pid)
        flunk("Defdo.DevIdp started outside :dev/:test")
    end
  end

  defp start(opts) do
    {:ok, pid} = Defdo.DevIdp.start_link(opts)
    {:started, pid}
  rescue
    error in BootError -> {:refused, error}
  end

  test "host env :prod refuses to start and leaves no supervisor" do
    Application.put_env(:defdo_auth_client, :env, :prod)

    error = refused_without_supervisor()
    assert error.reason == {:env_not_allowed, :prod}
    assert Exception.message(error) =~ ":prod"
    assert Exception.message(error) =~ "config :defdo_auth_client, :env, config_env()"
  end

  test "an undeclared host env counts as :prod and refuses to start" do
    Application.delete_env(:defdo_auth_client, :env)

    error = refused_without_supervisor()
    assert error.reason == {:env_not_allowed, :prod}
  end

  test "the site records are never read outside :dev and :test" do
    Application.put_env(:defdo_auth_client, :env, :prod)
    parent = self()
    reader = fn _tenant_ids -> send(parent, :site_read) && [] end

    refused_without_supervisor(Fixtures.opts(site_reader: reader))

    refute_received :site_read
  end

  for env <- [:dev, :test] do
    test "host env #{inspect(env)} starts the server" do
      Application.put_env(:defdo_auth_client, :env, unquote(env))

      pid = start_supervised!({Defdo.DevIdp, Fixtures.opts()})
      assert Process.whereis(Defdo.DevIdp) == pid
    end
  end
end
