defmodule Defdo.DevIdp.SeedCase do
  @moduledoc "A host as the seed task finds it: a vault project, dev credentials, no records."

  use ExUnit.CaseTemplate

  alias Defdo.DevIdp.FakeConsumer
  alias Defdo.DevIdp.FakeStore
  alias Defdo.DevIdp.TestLog

  @vault_tenant "11111111-1111-4111-8111-111111111111"

  using do
    quote do
      import Defdo.DevIdp.SeedCase, only: [provision_opts: 0, vault_tenant: 0, put_app_record: 1]
    end
  end

  setup do
    previous = %{
      auth: Application.get_env(:defdo_auth_client, Defdo.AuthClient),
      record: Application.get_env(:defdo_auth_client, Defdo.AuthClient.Site),
      consumer: Application.get_env(:defdo_vault, :consumer),
      credentials: Application.get_env(:defdo_vault, :credentials)
    }

    Application.put_env(:defdo_auth_client, Defdo.AuthClient,
      site: [vault_project: "dev_idp_test"]
    )

    Application.delete_env(:defdo_auth_client, Defdo.AuthClient.Site)

    Application.put_env(:defdo_vault, :consumer, FakeConsumer)
    Application.put_env(:defdo_vault, :credentials, transport: :local, tenant_id: @vault_tenant)

    start_supervised!(TestLog)
    start_supervised!(FakeStore)
    start_supervised!(FakeConsumer)

    on_exit(fn ->
      restore(:defdo_auth_client, Defdo.AuthClient, previous.auth)
      restore(:defdo_auth_client, Defdo.AuthClient.Site, previous.record)
      restore(:defdo_vault, :consumer, previous.consumer)
      restore(:defdo_vault, :credentials, previous.credentials)
    end)

    :ok
  end

  def vault_tenant, do: @vault_tenant

  @doc "Puts an app record in place, where the vault Runtime writes it."
  def put_app_record(record) do
    Application.put_env(:defdo_auth_client, Defdo.AuthClient.Site, app_record: record)
  end

  @doc "Provision options that need no database: the fake store and an identity transaction."
  def provision_opts do
    [
      store: FakeStore,
      steps: [],
      transaction: fn fun -> fun.() end,
      tenant_id: fn ctx -> ctx.params["tenant_id"] end
    ]
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
