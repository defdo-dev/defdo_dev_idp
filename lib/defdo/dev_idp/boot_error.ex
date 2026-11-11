defmodule Defdo.DevIdp.BootError do
  @moduledoc """
  Raised when the dev IdP refuses to start: the host environment is not
  `:dev`/`:test`, the config block is incomplete, a
  configured site points at another IdP, or the site records cannot be read.
  """

  defexception [:reason, :host]

  @impl Exception
  def message(%__MODULE__{reason: reason, host: host}) do
    "defdo_dev_idp refused to start for #{host_label(host)}: " <> describe(reason)
  end

  defp host_label(nil), do: "an unnamed host"
  defp host_label(host), do: ":" <> to_string(host)

  defp describe({:missing_config, keys}) do
    "`config :defdo_dev_idp` is missing " <>
      Enum.map_join(keys, ", ", &inspect/1) <> ". Add the block to the host's config/dev.exs."
  end

  defp describe({:env_not_allowed, host_env}) do
    "the host environment is #{inspect(host_env)}; the dev IdP only runs in :dev or :test. " <>
      "Declare it in the host's config/config.exs with " <>
      "`config :defdo_auth_client, :env, config_env()` (an undeclared env counts as :prod), " <>
      "and never start `Defdo.DevIdp` in production."
  end

  defp describe({:site_mismatch, remote, expected}) do
    "the Site record points at #{Enum.join(remote, ", ")}, not at this dev IdP (#{expected}). " <>
      "A dev login must never reach a real IdP. Run `mix defdo_dev_idp.seed`, or remove " <>
      "`Defdo.DevIdp` from this environment."
  end

  defp describe({:site_lookup_failed, exception}) do
    "the Site records could not be read (#{inspect(exception)}). " <>
      "Place `Defdo.DevIdp` after your Repo and vault children."
  end

  defp describe(_reason), do: "the boot check failed."
end
