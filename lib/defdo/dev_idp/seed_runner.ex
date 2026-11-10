defmodule Defdo.DevIdp.SeedRunner do
  @moduledoc """
  Seeds a host for the dev IdP, in this order:

    1. tenants — one per distinct profile tenant, through
       `Defdo.Tenant.Provision.run/2`;
    2. the app `Site` record, under the dev vault tenant;
    3. one customer `Site` record per other profile tenant;
    4. a boot re-check, so a running dev IdP becomes `ready`.

  Every record is written through `Defdo.AuthClient.Site.put/2`, the same writer
  hosts use, and carries the dev-IdP mark (`idp_mark`, vault code
  `auth.idp_mark`). A second run changes nothing; a record of this dev IdP
  without the mark is rewritten with it. A record that points at another site
  is never overwritten: this task only replaces what it could have written.

  `opts[:provision_opts]` is merged over the provision call's options. It is a
  scoped parameter for this package's own tests; the task never passes it.
  """

  alias Defdo.AuthClient.Env
  alias Defdo.AuthClient.Site
  alias Defdo.AuthClient.Site.Client
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Mark
  alias Defdo.Tenant.Context
  alias Defdo.Tenant.Provision
  alias Defdo.Tenant.Provision.Result
  alias Defdo.Tenant.Provision.Steps
  alias Defdo.Vault.Credentials

  @connection "dev-connection"
  @service_scopes "api:admin"

  @type error ::
          {:provision_failed, String.t(), term()}
          | {:no_provision_repo}
          | {:vault_credentials, term()}
          | {:foreign_app_record, String.t()}
          | {:foreign_site_record, String.t(), String.t()}
          | {:site_put_failed, :app | String.t(), term()}

  @spec run(Config.t(), keyword()) :: {:ok, [String.t()]} | {:error, error()}
  def run(%Config{} = config, opts \\ []) do
    with {:ok, tenant_lines} <- provision_tenants(config, opts),
         {:ok, app_line} <- app_record(config),
         {:ok, customer_lines} <- customer_records(config) do
      {:ok, tenant_lines ++ [app_line] ++ customer_lines ++ [recheck_line()]}
    end
  end

  @doc "The dev IdP's base URL as the seeded records name it."
  @spec base_url(Config.t()) :: String.t()
  def base_url(%Config{port: port}), do: "http://localhost:#{port}"

  @doc "The dev service client derived from the login client."
  @spec service_client(Config.t()) :: %{id: String.t(), secret: String.t()}
  def service_client(%Config{client: client}) do
    %{id: client.id <> "-svc", secret: client.secret <> "-svc"}
  end

  @spec format_error(error() | term()) :: String.t()
  def format_error({:provision_failed, tenant_id, _reason}),
    do: "defdo_dev_idp.seed: provisioning tenant #{tenant_id} failed"

  def format_error({:no_provision_repo}),
    do: "defdo_dev_idp.seed: set `provision: [repo: MyHost.Repo]` in config :defdo_dev_idp"

  def format_error({:vault_credentials, _reason}),
    do:
      "defdo_dev_idp.seed: the dev vault credentials (config :defdo_vault, :credentials) could not be read"

  def format_error({:foreign_app_record, site}),
    do: "defdo_dev_idp.seed: the app Site record points at #{site}; refusing to overwrite it"

  def format_error({:foreign_site_record, tenant_id, site}),
    do:
      "defdo_dev_idp.seed: the Site record of tenant #{tenant_id} points at #{site}; refusing to overwrite it"

  def format_error({:site_put_failed, :app, _reason}),
    do: "defdo_dev_idp.seed: writing the app Site record failed"

  def format_error({:site_put_failed, tenant_id, _reason}),
    do: "defdo_dev_idp.seed: writing the Site record of tenant #{tenant_id} failed"

  def format_error(_reason), do: "defdo_dev_idp.seed failed"

  # ── tenants ─────────────────────────────────────────────────────────────────

  defp provision_tenants(config, opts) do
    case Keyword.get(config.provision, :repo) do
      nil -> {:error, {:no_provision_repo}}
      repo -> provision_each(tenants(config), repo, Keyword.get(opts, :provision_opts, []))
    end
  end

  defp provision_each(tenants, repo, extra) do
    tenants
    |> Enum.reduce_while({:ok, []}, fn {tenant_id, label}, {:ok, lines} ->
      case provision(tenant_id, label, repo, extra) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse()
  end

  defp provision(tenant_id, label, repo, extra) do
    params = %{"name" => label, "domain" => "localhost", "tenant_id" => tenant_id}

    opts =
      Keyword.merge(
        [
          source: :dev_idp_seed,
          idempotency_key: tenant_id,
          steps: Steps.from_adapters(),
          repo: repo
        ],
        extra
      )

    case Provision.run(params, opts) do
      {:ok, %Result{already_processed?: true}} -> {:ok, "tenant #{tenant_id}: unchanged"}
      {:ok, %Result{}} -> {:ok, "tenant #{tenant_id}: provisioned"}
      {:error, reason, %Result{}} -> {:error, {:provision_failed, tenant_id, reason}}
      {:error, reason} -> {:error, {:provision_failed, tenant_id, reason}}
    end
  end

  # Distinct tenants in profile order, each with a sample display name.
  defp tenants(config) do
    config.profiles
    |> Enum.uniq_by(& &1.tenant_id)
    |> Enum.map(&{&1.tenant_id, label_for(&1)})
  end

  # "Operator · Defdo Red" → "Defdo Red (sample)".
  defp label_for(profile) do
    name =
      case String.split(profile.label, " · ", parts: 2) do
        [_role, tenant_name] -> tenant_name
        _other -> profile.tenant
      end

    name <> " (sample)"
  end

  # ── app record ──────────────────────────────────────────────────────────────

  defp app_record(config) do
    base = base_url(config)

    case Site.resolve(%{}) do
      {:ok, %Client{site: ^base} = client} -> app_record_for(config, client)
      {:ok, %Client{site: site}} -> {:error, {:foreign_app_record, site}}
      {:error, _missing} -> write_app_record(config)
    end
  end

  defp app_record_for(config, client) do
    desired = app_content(config)

    if client.client_id == desired["client_id"] and client.tenant == desired["tenant"] and
         marked?(client) do
      {:ok, "app record: unchanged"}
    else
      write_app_record(config)
    end
  end

  defp write_app_record(config) do
    with {:ok, vault_tenant} <- vault_tenant(),
         {:ok, %Client{}} <- Site.put(%{vault_tenant_id: vault_tenant}, app_content(config)) do
      {:ok, "app record: written"}
    else
      {:error, {:vault_credentials, _reason}} = error -> error
      {:error, reason} -> {:error, {:site_put_failed, :app, reason}}
    end
  end

  defp vault_tenant do
    case Credentials.read(env: Env.current()) do
      {:ok, %{tenant_id: tenant_id}} when is_binary(tenant_id) and tenant_id != "" ->
        {:ok, tenant_id}

      {:ok, _credentials} ->
        {:error, {:vault_credentials, :no_tenant_id}}

      {:error, reason} ->
        {:error, {:vault_credentials, reason}}
    end
  end

  defp app_content(config) do
    first = hd(config.profiles)
    service = service_client(config)

    %{
      "site" => base_url(config),
      "tenant" => first.tenant_id,
      "connection" => @connection,
      "client_id" => config.client.id,
      "client_secret" => config.client.secret,
      "redirect_uri" => config.redirect_uri,
      "scopes" => scopes(config.profiles),
      "service_client_id" => service.id,
      "service_client_secret" => service.secret,
      "service_scopes" => @service_scopes,
      "internal_api_token" => config.internal_api_token
    }
    |> Map.merge(config.app_record_extra)
    |> put_mark()
  end

  # ── customer records ────────────────────────────────────────────────────────

  defp customer_records(config) do
    first = hd(config.profiles).tenant_id

    config.profiles
    |> Enum.map(& &1.tenant_id)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == first))
    |> Enum.reduce_while({:ok, []}, fn tenant_id, {:ok, lines} ->
      case in_tenant(config, tenant_id) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse()
  end

  # Every read and write of a customer record happens inside that tenant's context.
  defp in_tenant(config, tenant_id) do
    Context.with_context(tenant_id, fn -> customer_record(config, tenant_id) end)
  end

  defp customer_record(config, tenant_id) do
    base = base_url(config)

    case Site.resolve(%{tenant_id: tenant_id}) do
      {:ok, %Client{site: ^base} = client} -> customer_record_for(config, tenant_id, client)
      {:ok, %Client{site: site}} -> {:error, {:foreign_site_record, tenant_id, site}}
      {:error, _missing} -> write_customer_record(config, tenant_id)
    end
  end

  defp customer_record_for(config, tenant_id, client) do
    if marked?(client) do
      {:ok, "site record #{tenant_id}: unchanged"}
    else
      write_customer_record(config, tenant_id)
    end
  end

  defp write_customer_record(config, tenant_id) do
    case Site.put(%{tenant_id: tenant_id}, customer_content(config, tenant_id)) do
      {:ok, %Client{}} -> {:ok, "site record #{tenant_id}: written"}
      {:error, reason} -> {:error, {:site_put_failed, tenant_id, reason}}
    end
  end

  defp customer_content(config, tenant_id) do
    profiles = Enum.filter(config.profiles, &(&1.tenant_id == tenant_id))

    %{
      "site" => base_url(config),
      "tenant" => tenant_id,
      "connection" => @connection,
      "client_id" => config.client.id,
      "client_secret" => config.client.secret,
      "redirect_uri" => config.redirect_uri,
      "scopes" => scopes(profiles)
    }
    |> Map.merge(config.app_record_extra)
    |> put_mark()
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The mark goes on last: `app_record_extra` cannot remove or replace it.
  defp put_mark(content), do: Map.put(content, Mark.record_field(), Mark.value())

  # A record of this dev IdP written before the mark existed counts as changed.
  defp marked?(%Client{idp_mark: mark}), do: mark == Mark.value()

  defp recheck_line do
    if Process.whereis(Defdo.DevIdp) do
      case Defdo.DevIdp.recheck() do
        {:ok, boot} -> "dev idp: #{boot}"
        {:error, _reason} -> "dev idp: refused (a Site record points elsewhere)"
      end
    else
      "dev idp: not running"
    end
  end

  defp scopes(profiles) do
    profiles |> Enum.flat_map(& &1.scopes) |> Enum.uniq() |> Enum.join(" ")
  end

  defp reverse({:ok, lines}), do: {:ok, Enum.reverse(lines)}
  defp reverse(error), do: error
end
