defmodule Defdo.DevIdp do
  @moduledoc """
  Dev-only mock IdP, supervised by the HOST.

  Add `Defdo.DevIdp` to the host's children AFTER its Repo and vault children:
  the boot check reads `Defdo.AuthClient.Site.sites/1`, which needs both.

  The server starts in one of two states:

    * `:ready` — every configured site points at this dev IdP;
    * `:unseeded` — no site record exists yet. Every page but the index answers
      503 until `mix defdo_dev_idp.seed` has run.

  It refuses to start (`Defdo.DevIdp.BootError`) when a configured site points
  elsewhere, or when the `config :defdo_dev_idp` block is incomplete. Without
  `enabled: true` it returns `:ignore`.
  """

  use Supervisor

  require Logger

  alias Defdo.DevIdp.Boot
  alias Defdo.DevIdp.BootError
  alias Defdo.DevIdp.Config
  alias Defdo.DevIdp.Keys
  alias Defdo.DevIdp.State
  alias Defdo.DevIdp.Store
  alias Defdo.DevIdp.Web.Router

  @listener :listener

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    case Config.fetch(opts) do
      {:error, :disabled} -> :ignore
      {:error, reason} -> raise BootError, reason: reason, host: Config.host(opts)
      {:ok, config} -> start_checked(config)
    end
  end

  @doc "The port the listener is bound to (the configured one, or the OS-assigned one for `port: 0`)."
  @spec port() :: :inet.port_number()
  def port do
    {:ok, {_ip, port}} = listener_info()
    port
  end

  @doc "The address and port the listener is bound to."
  @spec listener_info() :: {:ok, {:inet.ip_address(), :inet.port_number()}} | :error
  def listener_info do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.find_value(:error, fn
      {@listener, pid, _type, _modules} when is_pid(pid) -> ThousandIsland.listener_info(pid)
      _child -> nil
    end)
  end

  @doc """
  Re-runs the boot check and records the result. The seed task calls it after
  writing the site records; requests call it while the state is `:unseeded`.
  """
  @spec recheck() :: {:ok, State.boot()} | {:error, term()}
  def recheck do
    case Boot.check(State.config()) do
      {:ok, boot} ->
        State.put(boot)
        {:ok, boot}

      {:error, _reason} = error ->
        error
    end
  end

  @impl Supervisor
  def init({%Config{} = config, boot}) do
    children = [
      {State, {config, boot}},
      Store,
      Keys,
      Supervisor.child_spec(
        {Bandit, plug: {Router, config}, ip: {127, 0, 0, 1}, port: config.port, scheme: :http},
        id: @listener
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp start_checked(config) do
    case Boot.check(config) do
      {:ok, boot} ->
        with {:ok, pid} <- Supervisor.start_link(__MODULE__, {config, boot}, name: __MODULE__) do
          log_started(config, boot)
          {:ok, pid}
        end

      {:error, reason} ->
        raise BootError, reason: reason, host: config.host
    end
  end

  defp log_started(config, boot) do
    Logger.info(
      "defdo_dev_idp listening on http://localhost:#{port()} for :#{config.host} " <>
        "(#{length(config.profiles)} profiles, #{boot})"
    )

    if boot == :unseeded do
      Logger.warning("defdo_dev_idp: no Site record yet — run mix defdo_dev_idp.seed")
    end
  end
end
