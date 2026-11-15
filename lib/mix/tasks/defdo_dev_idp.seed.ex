defmodule Mix.Tasks.DefdoDevIdp.Seed do
  @shortdoc "Seeds dev tenants and the Site vault records for every dev IdP profile (dev/test only)"

  @moduledoc """
  Seeds a host for the dev IdP.

      mix defdo_dev_idp.seed

  It provisions one tenant per distinct profile tenant, writes the app `Site`
  record and one customer `Site` record per other tenant, then re-checks the
  dev IdP so it becomes `ready`. Running it again changes nothing.

  It refuses to run unless the host states `config :defdo_auth_client, :env` as
  `:dev` or `:test`.
  """

  use Mix.Task

  alias Defdo.AuthClient.Env
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.SeedRunner

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    # The host's stated env, not the Mix environment: a dependency is compiled
    # as :prod inside a host build.
    ensure_env!(Env.current())

    # On a fresh database the dev IdP comes up unseeded. That is expected here.
    Mix.Task.run("app.start")

    shell = Mix.shell()

    case SeedRunner.run(Config.fetch!()) do
      {:ok, lines} -> Enum.each(lines, &shell.info/1)
      {:error, reason} -> Mix.raise(SeedRunner.format_error(reason))
    end
  end

  @doc false
  @spec ensure_env!(atom()) :: :ok
  def ensure_env!(env) when env in [:dev, :test], do: :ok

  def ensure_env!(env) do
    Mix.raise(
      "defdo_dev_idp.seed runs only when config :defdo_auth_client, :env is :dev or :test " <>
        "(got #{inspect(env)})"
    )
  end
end
