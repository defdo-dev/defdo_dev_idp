defmodule Defdo.DevIdp.Web.Unseeded do
  @moduledoc """
  While the server is `:unseeded`, answers 503 on every page but the index.

  It re-runs the boot check once per request in that state only, so the server
  recovers as soon as the seed task has written the site records.
  """

  @behaviour Plug

  import Plug.Conn

  alias Defdo.DevIdp.State

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/"} = conn, _opts), do: conn

  def call(conn, _opts) do
    if seeded?(), do: conn, else: refuse(conn)
  end

  defp seeded? do
    State.get() == :ready or match?({:ok, :ready}, Defdo.DevIdp.recheck())
  end

  defp refuse(conn) do
    host = conn.assigns.config.host
    text = "Dev IdP for :#{host} has no Site record. Run `mix defdo_dev_idp.seed`."

    if wants_json?(conn) do
      body = Jason.encode!(%{error: "unseeded", error_description: text})
      conn |> put_resp_content_type("application/json") |> send_resp(503, body) |> halt()
    else
      body = "<!doctype html><title>Dev IdP</title><p>" <> escape(text) <> "</p>"
      conn |> put_resp_content_type("text/html") |> send_resp(503, body) |> halt()
    end
  end

  defp wants_json?(conn) do
    conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "application/json"))
  end

  defp escape(text), do: text |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()
end
