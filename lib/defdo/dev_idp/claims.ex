defmodule Defdo.DevIdp.Claims do
  @moduledoc """
  The one place that builds what the dev IdP says about a token. The two
  introspection endpoints and userinfo all answer from here.

  The active payload carries both scope spellings (`scope` string, `scopes`
  list) and all three tenant spellings (`tenant.id`, `tenant_id`) on purpose:
  host readers accept either. The inactive answer is always exactly
  `%{"active" => false}`.
  """

  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Profile
  alias Defdo.DevIdp.Store

  @inactive %{"active" => false}

  @spec inactive() :: map()
  def inactive, do: @inactive

  @doc "The introspection payload for a token string: active claims, or the inactive answer."
  @spec introspect(Config.t(), term()) :: map()
  def introspect(%Config{} = config, token) do
    case lookup(config, token) do
      {:ok, record, profile} -> for_token(record, profile)
      :error -> @inactive
    end
  end

  @doc "The token's record and profile, when the token is live."
  @spec lookup(Config.t(), term()) :: {:ok, map(), Profile.t()} | :error
  def lookup(%Config{} = config, token) do
    with {:ok, record} <- Store.get_token(token),
         %Profile{} = profile <- Enum.find(config.profiles, &(&1.key == record.profile_key)) do
      {:ok, record, profile}
    else
      _unknown -> :error
    end
  end

  @spec for_token(map(), Profile.t()) :: map()
  def for_token(record, %Profile{} = profile) do
    %{
      "active" => true,
      "sub" => profile.sub,
      "username" => profile.email,
      "email" => profile.email,
      "name" => profile.name,
      "client_id" => record.client_id,
      "token_type" => "Bearer",
      "exp" => record.expires_at,
      "iat" => record.issued_at,
      "scope" => Enum.join(record.scope, " "),
      "scopes" => record.scope,
      "tenant" => %{"id" => profile.tenant_id},
      "tenant_id" => profile.tenant_id,
      "roles" => [profile.role]
    }
  end

  @spec userinfo(map(), Profile.t()) :: map()
  def userinfo(record, %Profile{} = profile) do
    %{
      "sub" => profile.sub,
      "email" => profile.email,
      "email_verified" => true,
      "name" => profile.name,
      "preferred_username" => profile.email,
      "tenant_id" => profile.tenant_id,
      "roles" => [profile.role],
      "scope" => Enum.join(record.scope, " ")
    }
  end
end
