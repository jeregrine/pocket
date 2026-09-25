defmodule Mix.Tasks.Pocket.Toolchain do
  use Mix.Task

  @shortdoc "Download and verify Pocket's pinned experimental AOT toolchain"
  @moduledoc """
  Downloads Pocket's pinned native toolchain into `.pocket/toolchains`.
  Writes `pocket.lock` (JSON); commit that file. No executable is run until
  its SHA-256 matches the manifest embedded in this version of Pocket.

  This explicitly trusts the upstream experimental build and Pocket's pinned
  digest. It is not an independent audit or a signature from the OTP team.
  """

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("Usage: mix pocket.toolchain")
    {path, _} = Pocket.Toolchain.ensure!(install: true)
    Mix.shell().info("Verified #{path}")
  end
end
