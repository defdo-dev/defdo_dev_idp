defmodule Defdo.DevIdp.Fixtures do
  @moduledoc "Start options for the package's own tests. Sample names are invented."

  @spec opts(keyword()) :: keyword()
  def opts(overrides \\ []) do
    Keyword.merge(
      [
        enabled: true,
        host: :defdo_gateway,
        port: 0,
        client: [id: "dev-gateway", secret: "dev-gateway-secret"],
        internal_api_token: "dev-internal-token",
        redirect_uri: "http://localhost:4000/oauth2/defdo_auth",
        profiles: profiles(),
        site_reader: fn _tenant_ids -> ["http://localhost:0"] end
      ],
      overrides
    )
  end

  @spec profiles() :: [map()]
  def profiles do
    [
      %{
        key: :operator,
        label: "Operator · Defdo Red",
        role: "operator",
        tenant: "dev-tenant",
        tenant_id: "00000000-0000-4000-8000-000000000001",
        scopes: ~w(openid profile ai:admin)
      },
      %{
        key: :customer,
        label: "Customer · Acme",
        role: "customer",
        tenant: "acme",
        scopes: ~w(openid profile)
      }
    ]
  end

  @spec url(String.t()) :: String.t()
  def url(path), do: "http://127.0.0.1:#{Defdo.DevIdp.port()}" <> path

  @spec get(String.t(), keyword()) :: Req.Response.t()
  def get(path, opts \\ []) do
    Req.get!(url(path), Keyword.merge([retry: false, redirect: false], opts))
  end
end
