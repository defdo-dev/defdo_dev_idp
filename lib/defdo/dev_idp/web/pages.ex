defmodule Defdo.DevIdp.Web.Pages do
  @moduledoc """
  The dev IdP's HTML pages: plain string templates, every value escaped.
  """

  alias Defdo.DevIdp.Config

  @spec index(Config.t(), :ready | :unseeded) :: String.t()
  def index(%Config{} = config, boot) do
    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Dev IdP · #{e(config.host)}</title></head>
    <body>
    <main>
    <h1>Dev IdP for :#{e(config.host)}</h1>
    <p>State: <strong>#{e(boot)}</strong>#{hint(boot)}</p>
    <h2>Profiles</h2>
    <ul>
    #{Enum.map_join(config.profiles, "\n", &profile/1)}
    </ul>
    <form method="post" action="/sign-out">
    <button type="submit">Sign out everywhere</button>
    </form>
    </main>
    </body>
    </html>
    """
  end

  defp hint(:unseeded), do: " — no Site record yet. Run <code>mix defdo_dev_idp.seed</code>."
  defp hint(_boot), do: ""

  defp profile(profile) do
    "<li>#{e(profile.label)} — <code>#{e(profile.sub)}</code>, tenant <code>#{e(profile.tenant_id)}</code></li>"
  end

  @doc "Escapes a value for HTML. Every interpolation on a page goes through it."
  @spec e(term()) :: String.t()
  def e(value) do
    value |> to_string() |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()
  end
end
