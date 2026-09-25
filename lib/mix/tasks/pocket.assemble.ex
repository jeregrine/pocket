defmodule Mix.Tasks.Pocket.Assemble do
  use Mix.Task
  @moduledoc false

  @impl true
  def run([]) do
    toolchain = System.fetch_env!("POCKET_TOOLCHAIN")

    # This task must only run inside the verified backend, never host ERTS.
    case :init.get_argument(:primary_archive) do
      {:ok, _} -> :ok
      _ -> Mix.raise("pocket.assemble is internal; use mix pocket.build")
    end

    {^toolchain, manifest} = Pocket.Toolchain.ensure!(offline: true)
    Mix.Task.run("compile")

    Pocket.Builder.build!(
      Pocket.Config.read!(),
      System.fetch_env!("POCKET_OUTPUT"),
      toolchain,
      manifest
    )
  end
end
