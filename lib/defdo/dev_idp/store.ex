defmodule Defdo.DevIdp.Store do
  @moduledoc """
  Codes, tokens and dev sessions, in memory.

  Stub: slice 05 replaces it with the ETS-backed store. It exists now so the
  supervision tree already has its final shape.
  """

  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
end
