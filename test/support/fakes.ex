defmodule Defdo.DevIdp.TestLog do
  @moduledoc "An ordered log of what the fakes were asked to do."

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def add(event), do: Agent.update(__MODULE__, &[event | &1])
  def events, do: Agent.get(__MODULE__, &Enum.reverse/1)
  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)
end

defmodule Defdo.DevIdp.FakeStore do
  @moduledoc "An in-memory `Defdo.Tenant.Provision.Store`."

  @behaviour Defdo.Tenant.Provision.Store

  use Agent

  alias Defdo.DevIdp.TestLog

  defmodule Record do
    @moduledoc false
    defstruct [:id, :status, :tenant_id, :source, :idempotency_key, attempts: 0]
  end

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl true
  def claim(source, key, _attrs, _opts) do
    Agent.get_and_update(__MODULE__, fn records ->
      case Map.fetch(records, {source, key}) do
        {:ok, record} ->
          {{:already_claimed, record}, records}

        :error ->
          record = %Record{
            id: "prov-" <> key,
            status: "received",
            source: source,
            idempotency_key: key
          }

          TestLog.add({:provision, key})
          {{:ok, record}, Map.put(records, {source, key}, record)}
      end
    end)
  end

  @impl true
  def mark_processing(record, _opts) do
    save(%{record | status: "processing", attempts: record.attempts + 1})
  end

  @impl true
  def mark_provisioned(record, tenant_id, _opts) do
    save(%{record | status: "provisioned", tenant_id: tenant_id})
  end

  @impl true
  def mark_failed(record, _error, _opts), do: save(%{record | status: "failed"})

  defp save(record) do
    Agent.update(__MODULE__, &Map.put(&1, {record.source, record.idempotency_key}, record))
    {:ok, record}
  end
end

defmodule Defdo.DevIdp.FakeConsumer do
  @moduledoc """
  An in-memory `Defdo.Vault.Consumer`.

  App codes (`auth.*`) are also copied into the application environment, which
  is what `Defdo.Vault.Runtime` does in a host. Customer records are kept per
  tenant, keyed by the tenant in `Defdo.Tenant.Context` at call time.
  """

  @behaviour Defdo.Vault.Consumer

  use Agent

  alias Defdo.DevIdp.TestLog
  alias Defdo.Tenant.Context

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Puts a customer record in place, as if another writer had created it."
  def put_customer(tenant_id, content) do
    Agent.update(__MODULE__, &Map.put(&1, tenant_id, content))
  end

  @impl true
  def upsert_secret(%{code: "auth." <> key, content: %{"value" => value}}, _opts) do
    TestLog.add({:app_code, key, Context.tenant_id()})
    runtime_put(key, value)
    {:ok, :written}
  end

  def upsert_secret(%{code: "defdo_auth_client", content: content}, _opts) do
    tenant_id = Context.tenant_id()
    TestLog.add({:customer_record, tenant_id})
    Agent.update(__MODULE__, &Map.put(&1, tenant_id, content))
    {:ok, :written}
  end

  @impl true
  def resolve_secret(_project, "defdo_auth_client", _opts) do
    tenant_id = Context.tenant_id()

    case Agent.get(__MODULE__, &Map.fetch(&1, tenant_id)) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def resolve_value(_reference, _opts), do: {:error, :not_found}

  @impl true
  def build_secret_reference(_project, _identifier, _opts), do: {:error, :not_supported}

  defp runtime_put("internal_api_token", _value), do: :ok

  defp runtime_put(key, value) do
    current = Application.get_env(:defdo_auth_client, Defdo.AuthClient, [])
    site = current |> Keyword.get(:site, []) |> Keyword.put(String.to_existing_atom(key), value)
    Application.put_env(:defdo_auth_client, Defdo.AuthClient, Keyword.put(current, :site, site))
  end
end
