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

  @doc """
  The profile picker: one form per profile. Each form carries the validated
  request as hidden fields plus the `picker_token` bound to it.
  """
  @spec picker(Config.t(), map(), String.t()) :: String.t()
  def picker(%Config{} = config, request, picker_token) do
    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Dev IdP · sign in to #{e(config.host)}</title></head>
    <body>
    <main>
    <h1>Sign in to :#{e(config.host)}</h1>
    <p>Dev IdP — not a real login.</p>
    #{Enum.map_join(config.profiles, "\n", &card(&1, request, picker_token))}
    </main>
    </body>
    </html>
    """
  end

  defp card(profile, request, picker_token) do
    """
    <form method="post" action="/oauth/authorize">
    #{hidden("response_type", "code")}
    #{hidden("code_challenge_method", "S256")}
    #{hidden("client_id", request.client_id)}
    #{hidden("redirect_uri", request.redirect_uri)}
    #{hidden("state", request.state)}
    #{hidden("code_challenge", request.code_challenge)}
    #{hidden("scope", request.scope)}
    #{hidden("nonce", request.nonce)}
    #{hidden("picker_token", picker_token)}
    #{hidden("profile", profile.key)}
    <h2>#{e(profile.label)}</h2>
    <p><code>#{e(profile.sub)}</code> · tenant <code>#{e(profile.tenant_id)}</code></p>
    <button type="submit">Continue as #{e(profile.label)}</button>
    </form>
    """
  end

  defp hidden(_name, nil), do: ""
  defp hidden(name, value), do: ~s(<input type="hidden" name="#{e(name)}" value="#{e(value)}">)

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
