defmodule Defdo.DevIdp.Config do
  @moduledoc """
  The `config :defdo_dev_idp` block, validated.

  Hosts set it in `config/dev.exs` only. Tests start the server with explicit
  options, which are merged over the application environment.

  `:site_reader` is the one value that is NOT configuration: it is a start
  option of the server (`{Defdo.DevIdp, site_reader: fun}`), scoped to that
  server, and is never read from the application environment. It defaults to
  `Defdo.AuthClient.Site.sites/1`.
  """

  alias Defdo.DevIdp.Profile

  @required [:host, :port, :client, :internal_api_token, :redirect_uri, :profiles]
  @start_only [:site_reader]

  @enforce_keys @required
  defstruct @required ++ [provision: [], site_record_extra: %{}, site_reader: nil]

  @type site_reader :: ([String.t()] -> [String.t()])

  @type t :: %__MODULE__{
          host: atom(),
          port: :inet.port_number(),
          client: %{id: String.t(), secret: String.t()},
          internal_api_token: String.t(),
          redirect_uri: String.t(),
          profiles: [Profile.t()],
          provision: keyword(),
          site_record_extra: map(),
          site_reader: site_reader() | nil
        }

  @spec fetch(keyword()) ::
          {:ok, t()} | {:error, :disabled} | {:error, {:missing_config, [atom()]}}
  def fetch(opts \\ []) do
    settings = merged(opts)

    cond do
      Keyword.get(settings, :enabled) != true -> {:error, :disabled}
      missing(settings) != [] -> {:error, {:missing_config, missing(settings)}}
      true -> {:ok, build(settings, Keyword.get(opts, :site_reader))}
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

  # Start-only options never come from the application environment.
  defp merged(opts) do
    :defdo_dev_idp
    |> Application.get_all_env()
    |> Keyword.drop(@start_only)
    |> Keyword.merge(Keyword.drop(opts, @start_only))
  end

  defp missing(settings), do: Enum.reject(@required, &Keyword.has_key?(settings, &1))

  defp build(settings, site_reader) do
    client = Map.new(Keyword.fetch!(settings, :client))

    %__MODULE__{
      host: Keyword.fetch!(settings, :host),
      port: Keyword.fetch!(settings, :port),
      client: %{id: Map.fetch!(client, :id), secret: Map.fetch!(client, :secret)},
      internal_api_token: Keyword.fetch!(settings, :internal_api_token),
      redirect_uri: Keyword.fetch!(settings, :redirect_uri),
      profiles: settings |> Keyword.fetch!(:profiles) |> Profile.list!(),
      provision: Keyword.get(settings, :provision, []),
      site_record_extra: Keyword.get(settings, :site_record_extra, %{}),
      site_reader: site_reader!(site_reader)
    }
  end

  defp site_reader!(nil), do: nil
  defp site_reader!(reader) when is_function(reader, 1), do: reader

  defp site_reader!(_other) do
    raise ArgumentError, "defdo_dev_idp: :site_reader must be a function of one argument"
  end
end
