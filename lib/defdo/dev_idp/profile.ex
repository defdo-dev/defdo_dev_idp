defmodule Defdo.DevIdp.Profile do
  @moduledoc """
  One sign-in choice on the dev IdP's picker.

  Derived fields: `sub = "dev-<role>-<tenant>"`, `email = "<role>@<tenant>.dev.defdo"`,
  `name = label`; `tenant_id` defaults to `tenant`.
  """

  @enforce_keys [:key, :label, :role, :tenant, :tenant_id, :scopes, :sub, :email, :name]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          role: String.t(),
          tenant: String.t(),
          tenant_id: String.t(),
          scopes: [String.t()],
          sub: String.t(),
          email: String.t(),
          name: String.t()
        }

  @slug ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    attrs = Map.new(attrs)
    key = fetch!(attrs, :key, &is_atom/1, "an atom")
    label = fetch!(attrs, :label, &non_empty?/1, "a non-empty string")
    role = fetch!(attrs, :role, &slug?/1, "lowercase letters, digits, - or _")
    tenant = fetch!(attrs, :tenant, &slug?/1, "lowercase letters, digits, - or _")
    scopes = fetch!(attrs, :scopes, &scopes?/1, "a list of strings")
    tenant_id = Map.get(attrs, :tenant_id, tenant)

    if not non_empty?(tenant_id) do
      raise ArgumentError, "defdo_dev_idp profile #{inspect(key)}: :tenant_id must be a string"
    end

    %__MODULE__{
      key: key,
      label: label,
      role: role,
      tenant: tenant,
      tenant_id: tenant_id,
      scopes: scopes,
      sub: "dev-" <> role <> "-" <> tenant,
      email: role <> "@" <> tenant <> ".dev.defdo",
      name: label
    }
  end

  @doc "Builds every profile and refuses duplicate keys or an empty list."
  @spec list!([map() | keyword()]) :: [t()]
  def list!(profiles) when is_list(profiles) and profiles != [] do
    built = Enum.map(profiles, &new!/1)
    keys = Enum.map(built, & &1.key)

    if keys != Enum.uniq(keys) do
      raise ArgumentError, "defdo_dev_idp profiles: keys must be unique, got #{inspect(keys)}"
    end

    built
  end

  def list!(_profiles) do
    raise ArgumentError, "defdo_dev_idp profiles: expected a non-empty list"
  end

  defp fetch!(attrs, field, valid?, expected) do
    value = Map.get(attrs, field)

    if valid?.(value) do
      value
    else
      raise ArgumentError,
            "defdo_dev_idp profile #{inspect(Map.get(attrs, :key))}: #{inspect(field)} must be #{expected}"
    end
  end

  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""
  defp slug?(value), do: is_binary(value) and Regex.match?(@slug, value)
  defp scopes?(value), do: is_list(value) and Enum.all?(value, &non_empty?/1)
end
