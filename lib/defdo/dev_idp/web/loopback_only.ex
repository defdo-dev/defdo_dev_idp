defmodule Defdo.DevIdp.Web.LoopbackOnly do
  @moduledoc """
  Answers 404 to any peer that is not the loopback interface.

  The listener already binds `127.0.0.1`; this is the second enforcement, so a
  listener bound elsewhere by mistake still serves nobody.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback [
    {127, 0, 0, 1},
    {0, 0, 0, 0, 0, 0, 0, 1},
    {0, 0, 0, 0, 0, 65_535, 32_512, 1}
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{remote_ip: remote_ip} = conn, _opts) when remote_ip in @loopback, do: conn

  def call(conn, _opts) do
    conn |> send_resp(404, "Not found") |> halt()
  end
end
