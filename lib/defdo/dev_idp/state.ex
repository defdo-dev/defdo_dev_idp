defmodule Defdo.DevIdp.State do
  @moduledoc "Holds the boot state (`:ready | :unseeded`) and the validated config."

  use Agent

  alias Defdo.DevIdp.Config

  @type boot :: :ready | :unseeded

  @spec start_link({Config.t(), boot()}) :: Agent.on_start()
  def start_link({%Config{} = config, boot}) when boot in [:ready, :unseeded] do
    Agent.start_link(fn -> %{config: config, boot: boot} end, name: __MODULE__)
  end

  @spec get() :: boot()
  def get, do: Agent.get(__MODULE__, & &1.boot)

  @spec config() :: Config.t()
  def config, do: Agent.get(__MODULE__, & &1.config)

  @spec put(boot()) :: :ok
  def put(boot) when boot in [:ready, :unseeded] do
    Agent.update(__MODULE__, &%{&1 | boot: boot})
  end
end
