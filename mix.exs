defmodule Defdo.DevIdp.MixProject do
  use Mix.Project

  def project do
    [
      app: :defdo_dev_idp,
      version: "0.1.0",
      elixir: "~> 1.20",
      # The package's own test/support. This is the only Mix.env() allowed, and only here.
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      description:
        "Dev-only mock IdP speaking the defdo_auth OAuth2/OIDC subset, against Defdo.AuthClient.Site",
      package: [
        organization: "defdo",
        licenses: ["Proprietary"],
        files: ~w(lib scripts mix.exs README.md CHANGELOG.md)
      ]
    ]
  end

  # No application callback module: the host supervises Defdo.DevIdp after its Repo and vault.
  def application, do: [extra_applications: [:logger, :crypto, :public_key]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.13"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:defdo_auth_client, "~> 0.15", organization: :defdo},
      # Defdo.AuthClient.Site is only compiled when these two are present.
      {:defdo_vault, "~> 0.21", organization: :defdo},
      {:defdo_tenant, "~> 0.24", organization: :defdo},
      {:defdo_tenant_provision, "~> 0.3", organization: :defdo},
      {:stream_data, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
