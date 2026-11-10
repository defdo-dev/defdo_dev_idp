defmodule Defdo.DevIdp.Config do
  @moduledoc """
  The `config :defdo_dev_idp` block, validated.

  Hosts set it in `config/dev.exs` only. Tests start the server with explicit
  options, which are merged over the application environment.
  """

  alias Defdo.DevIdp.Profile

  @required [:host, :port, :client, :internal_api_token, :redirect_uri, :profiles]

  @enforce_keys @required
  defstruct @required ++ [provision: [], site_record_extra: %{}, site_reader: nil]

  @type t :: %__MODULE__{
          host: atom(),
          port: :inet.port_number(),
          client: %{id: String.t(), secret: String.t()},
          internal_api_token: String.t(),
          redirect_uri: String.t(),
          profiles: [Profile.t()],
          provision: keyword(),
          site_record_extra: map(),
          site_reader: ([String.t()] -> [String.t()]) | nil
        }

  @spec fetch(keyword()) ::
          {:ok, t()} | {:error, :disabled} | {:error, {:missing_config, [atom()]}}
  def fetch(opts \\ []) do
    env = merged(opts)

    cond do
      Keyword.get(env, :enabled) != true -> {:error, :disabled}
      missing(env) != [] -> {:error, {:missing_config, missing(env)}}
      true -> {:ok, build(env)}
    end
  end

  @spec fetch!(keyword()) :: t()
  def fetch!(opts \\ []) do
    case fetch(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise Defdo.DevIdp.BootError, reason: reason, host: host(opts)
    end
  end

  @doc "The configured host app, when the block names one."
  @spec host(keyword()) :: atom() | nil
  def host(opts \\ []), do: opts |> merged() |> Keyword.get(:host)

  defp merged(opts), do: Keyword.merge(Application.get_all_env(:defdo_dev_idp), opts)

  defp missing(env), do: Enum.reject(@required, &Keyword.has_key?(env, &1))

  defp build(env) do
    client = Map.new(Keyword.fetch!(env, :client))

    %__MODULE__{
      host: Keyword.fetch!(env, :host),
      port: Keyword.fetch!(env, :port),
      client: %{id: Map.fetch!(client, :id), secret: Map.fetch!(client, :secret)},
      internal_api_token: Keyword.fetch!(env, :internal_api_token),
      redirect_uri: Keyword.fetch!(env, :redirect_uri),
      profiles: env |> Keyword.fetch!(:profiles) |> Profile.list!(),
      provision: Keyword.get(env, :provision, []),
      site_record_extra: Keyword.get(env, :site_record_extra, %{}),
      site_reader: Keyword.get(env, :site_reader)
    }
  end
end
