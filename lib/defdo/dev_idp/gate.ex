defmodule Defdo.DevIdp.Gate do
  @moduledoc """
  The release gate, from Elixir: a production release tree must not contain the
  dev IdP.

  It is the `release` mode of `scripts/ci/assert-no-dev-idp.sh`, with the same
  bracketed check names, so a host can assert it from ExUnit.
  """

  @doc """
  Raises when `release_dir` is missing, or contains a `Defdo.DevIdp` beam or the
  `defdo_dev_idp` application directory.
  """
  @spec assert_absent!(Path.t()) :: :ok
  def assert_absent!(release_dir) when is_binary(release_dir) do
    lib = Path.join(release_dir, "lib")

    cond do
      not File.dir?(lib) ->
        raise "assert-no-dev-idp[release-dir]: not found: #{release_dir}"

      beams(lib) != [] ->
        raise "assert-no-dev-idp[beams]: Defdo.DevIdp beams present in #{release_dir}"

      app_dirs(lib) != [] ->
        raise "assert-no-dev-idp[app-dir]: defdo_dev_idp application present in #{lib}"

      true ->
        :ok
    end
  end

  defp beams(lib), do: Path.wildcard(Path.join(lib, "**/Elixir.Defdo.DevIdp*.beam"))
  defp app_dirs(lib), do: Path.wildcard(Path.join(lib, "defdo_dev_idp-*"))
end
