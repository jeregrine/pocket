defmodule Pocket.Config do
  @moduledoc false

  def read!(project \\ Mix.Project.config()) do
    if project[:apps_path], do: Mix.raise("Pocket v0.1 requires a non-umbrella CLI project")
    pocket = Keyword.get(project, :pocket, [])
    unless Keyword.keyword?(pocket), do: Mix.raise(":pocket must be a keyword list")
    unknown = Keyword.keys(pocket) -- [:main_module, :name, :shutdown_timeout]
    if unknown != [], do: Mix.raise("Unknown :pocket options: #{inspect(unknown)}")

    main = pocket[:main_module]

    unless is_atom(main) and main not in [nil, true, false] do
      Mix.raise("Set pocket: [main_module: MyApp.CLI] in mix.exs")
    end

    name = pocket[:name] || to_string(project[:app])

    unless is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, name) do
      Mix.raise("Pocket :name must be a filename containing letters, digits, '_' or '-'")
    end

    timeout = Keyword.get(pocket, :shutdown_timeout, 5_000)

    unless is_integer(timeout) and timeout in 1..60_000 do
      Mix.raise("Pocket :shutdown_timeout must be between 1 and 60000 milliseconds")
    end

    config_path = project[:config_path] || "config/config.exs"
    runtime_path = Path.join(Path.dirname(config_path), "runtime.exs")

    if File.exists?(runtime_path) do
      Mix.raise(
        "Pocket v0.1 does not support #{runtime_path} yet. " <>
          "Read runtime environment in your application; do not bake secrets into config."
      )
    end

    if project[:releases] not in [nil, []] do
      Mix.raise(
        "Pocket v0.1 does not consume custom :releases configuration yet; use a dedicated CLI project"
      )
    end

    %{
      app: project[:app],
      version: project[:version],
      main: main,
      name: name,
      shutdown_timeout: timeout
    }
  end
end
