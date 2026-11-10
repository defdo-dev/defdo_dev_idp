defmodule Defdo.DevIdp.Boot do
  @moduledoc """
  The boot check: do the configured sites point at this dev IdP?

  Three outcomes, one source (`Defdo.AuthClient.Site.sites/1`):

    * `{:ok, :ready}` — every site is this dev IdP;
    * `{:ok, :unseeded}` — there is no site record yet (a fresh database);
    * `{:error, {:site_mismatch, remote, expected}}` — a site points elsewhere.

  A lookup that raises (the host placed `Defdo.DevIdp` before its Repo or
  vault) is `{:error, {:site_lookup_failed, exception_module}}`.
  """

  alias Defdo.AuthClient.Site
  alias Defdo.DevIdp.Config

  @type outcome ::
          {:ok, :ready}
          | {:ok, :unseeded}
          | {:error, {:site_mismatch, [String.t()], String.t()}}
          | {:error, {:site_lookup_failed, module()}}

  @spec check(Config.t()) :: outcome()
  def check(%Config{} = config) do
    expected = ["http://localhost:#{config.port}", "http://127.0.0.1:#{config.port}"]
    tenant_ids = config.profiles |> Enum.map(& &1.tenant_id) |> Enum.uniq()

    case read_sites(config, tenant_ids) do
      {:ok, sites} -> classify(sites, expected)
      {:error, _reason} = error -> error
    end
  end

  defp classify(sites, expected) do
    case {sites, Enum.reject(sites, &(normalize(&1) in expected))} do
      {[], _remote} -> {:ok, :unseeded}
      {_sites, []} -> {:ok, :ready}
      {_sites, remote} -> {:error, {:site_mismatch, remote, hd(expected)}}
    end
  end

  # The app site plus the customer tenants' sites. `site_reader` exists so the
  # package's own tests can drive each outcome; hosts never set it.
  defp read_sites(%Config{site_reader: reader}, tenant_ids) when is_function(reader, 1) do
    {:ok, reader.(tenant_ids)}
  rescue
    error -> {:error, {:site_lookup_failed, error.__struct__}}
  end

  defp read_sites(_config, tenant_ids) do
    {:ok, Site.sites(tenant_ids)}
  rescue
    error -> {:error, {:site_lookup_failed, error.__struct__}}
  end

  defp normalize(site) when is_binary(site) do
    site |> String.trim() |> String.trim_trailing("/") |> String.downcase()
  end

  defp normalize(_site), do: ""
end
