defmodule Mix.Tasks.Pocket.Build do
  use Mix.Task

  @shortdoc "Build a single-executable Elixir CLI"
  @moduledoc """
  Builds the current project using a pinned, experimental AOT BEAM.

      mix pocket.build [--install] [--offline] [--output dist/name]

  Configure `pocket: [main_module: MyApp.CLI]` in `mix.exs`.
  `main/1` receives strings and returns `:ok` or `{:error, 1..255}`.

  Production compilation happens under the pinned toolchain, in a separate
  `_build/pocket` directory. Dependencies must already be fetched. This task
  never runs `deps.get`. Runtime dependency downloads are not supported.

  The default output is `dist/<app>`. Only native builds are supported.
  `--install` explicitly permits a missing toolchain download. `--offline`
  prevents toolchain downloads (it does not sandbox dependency build scripts).
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [install: :boolean, offline: :boolean, output: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix pocket.build [--install] [--offline] [--output PATH]")

    config = Pocket.Config.read!()
    {toolchain, manifest} = Pocket.Toolchain.ensure!(opts)
    output = Path.expand(opts[:output] || Path.join("dist", config.name))
    worker = Application.app_dir(:pocket, "priv/worker.exs")
    build_path = Path.expand("_build/pocket/#{manifest["id"]}/#{Pocket.Toolchain.target()}")

    env =
      Pocket.Toolchain.clean_env() ++
        [
          {"MIX_ENV", "prod"},
          {"MIX_TARGET", "host"},
          {"MIX_BUILD_PATH", build_path},
          {"POCKET_TOOLCHAIN", toolchain},
          {"POCKET_OUTPUT", output}
        ]

    Mix.shell().info(
      "Building #{config.name} for #{Pocket.Toolchain.target()} with pinned AOT BEAM"
    )

    {_, status} =
      System.cmd(toolchain, ["run", worker],
        env: env,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Pocket build failed (worker exit #{status})")
    Mix.shell().info("Built #{output}")
  end
end
