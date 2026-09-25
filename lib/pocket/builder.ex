defmodule Pocket.Builder do
  @moduledoc false

  @forbidden_apps [:mix, :hex, :iex, :pocket]
  @native_extensions ~w(.so .dylib .dll .a .o)

  def build!(config, output, toolchain, manifest) do
    {module, function, arity} =
      case config.main do
        module when is_atom(module) -> {module, :main, 1}
        {module, function, args} -> {module, function, length(args) + 1}
      end

    unless Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      Mix.raise("#{inspect(module)} must export #{function}/#{arity}")
    end

    applications = resolve!([config.app, :elixir, :logger])
    forbidden = Map.keys(applications) |> Enum.filter(&(&1 in @forbidden_apps))

    unless forbidden == [] do
      Mix.raise(
        "Build-only applications would ship: #{inspect(forbidden)}. " <>
          "Declare the Pocket dependency with runtime: false."
      )
    end

    File.mkdir_p!(Path.dirname(output))

    workspace =
      Path.join(
        Mix.Project.build_path(),
        "assemble-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir!(workspace)
    File.chmod!(workspace, 0o700)

    try do
      rel = Path.join(workspace, "release")
      entries = assemble!(config, applications, rel)
      emulator = toolchain |> File.read!() |> Pocket.Archive.emulator!()
      comment = boot_comment(config)
      recording = Path.join(workspace, "recording")
      File.mkdir_p!(recording)
      first = Path.join(workspace, "record")
      write_executable!(first, emulator, entries, comment)

      {log, status} =
        System.cmd(first, ["-erlaot:record", Path.expand(recording)],
          env: Pocket.Toolchain.clean_env(),
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("AOT recording failed (#{status}):\n#{log}")

      overlay = disk_entries(recording)

      unless Enum.any?(overlay, fn {name, _} -> String.ends_with?(name, "/jitc/atoms") end) do
        Mix.raise("AOT backend did not produce an atom snapshot")
      end

      final_entries = Map.merge(Map.new(entries), Map.new(overlay)) |> Map.to_list()
      # Build beside the destination, then atomically replace it. A failed build
      # leaves the last working executable untouched.
      staged = output <> "." <> Path.basename(workspace)

      try do
        write_executable!(staged, emulator, final_entries, comment)
        File.rename!(staged, output)
      after
        File.rm(staged)
      end

      report = %{
        "schema" => 1,
        "name" => config.name,
        "version" => config.version,
        "target" => Pocket.Toolchain.target(),
        "toolchain" => manifest["id"],
        "toolchain_sha256" => manifest["artifacts"][Pocket.Toolchain.target()]["sha256"],
        "elixir" => System.version(),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "erts" => to_string(:erlang.system_info(:version)),
        "executable_sha256" => Pocket.Toolchain.digest(output),
        "executable_bytes" => File.stat!(output).size,
        "applications" =>
          (Enum.map(applications, fn {app, spec} ->
             %{"name" => to_string(app), "version" => spec.version}
           end) ++ [%{"name" => "pocket_runtime", "version" => "0.1.0"}])
          |> Enum.sort_by(& &1["name"]),
        "files" => Enum.map(final_entries, &elem(&1, 0)) |> Enum.sort()
      }

      File.write!(output <> ".manifest.json", JSON.encode!(report) <> "\n")
    after
      File.rm_rf!(workspace)
    end
  end

  # Read OTP application metadata rather than guessing from module references.
  # An absent optional application is allowed; an ordinary missing dependency
  # is always a build error. Included applications are loaded but not started.
  def resolve!(roots), do: resolve(roots, %{})
  defp resolve([], acc), do: acc
  defp resolve([app | rest], acc) when is_map_key(acc, app), do: resolve(rest, acc)
  defp resolve([:erts | rest], acc), do: resolve(rest, acc)

  defp resolve([app | rest], acc) do
    dir =
      case :code.lib_dir(app) do
        {:error, _} -> Mix.raise("Missing runtime application #{inspect(app)}")
        path -> to_string(path)
      end

    {:application, ^app, properties} = consult!(Path.join([dir, "ebin", "#{app}.app"]))
    optional = Keyword.get(properties, :optional_applications, [])
    included = Keyword.get(properties, :included_applications, [])

    dependencies =
      (Keyword.get(properties, :applications, []) ++ included)
      |> Enum.reject(fn dependency ->
        dependency in optional and match?({:error, _}, :code.lib_dir(dependency))
      end)

    spec = %{
      dir: dir,
      version: properties |> Keyword.fetch!(:vsn) |> to_string(),
      included: included
    }

    resolve(dependencies ++ rest, Map.put(acc, app, spec))
  end

  defp assemble!(config, applications, rel) do
    Enum.each(applications, fn {app, spec} ->
      target = Path.join([rel, "lib", "#{app}-#{spec.version}", "ebin"])
      copy_tree!(Path.join(spec.dir, "ebin"), target)
      check_priv!(app, spec.dir)
    end)

    # Replace ordinary protocol BEAMs with the project's consolidated versions.
    consolidation = Mix.Project.consolidation_path()

    if File.dir?(consolidation) do
      for source <- Path.wildcard(Path.join(consolidation, "*.beam")) do
        matches = Path.wildcard(Path.join([rel, "lib", "*", "ebin", Path.basename(source)]))
        Enum.each(matches, &File.cp!(source, &1))
      end
    end

    runtime = Path.join([rel, "lib", "pocket_runtime-0.1.0", "ebin"])
    File.mkdir_p!(runtime)
    {Pocket.Runtime, beam, _} = :code.get_object_code(Pocket.Runtime)
    File.write!(Path.join(runtime, "Elixir.Pocket.Runtime.beam"), beam)

    write_term!(
      Path.join(runtime, "pocket_runtime.app"),
      {:application, :pocket_runtime,
       [
         description: ~c"Pocket CLI entry point",
         vsn: ~c"0.1.0",
         registered: [],
         modules: [Pocket.Runtime],
         applications: [:kernel, :stdlib, :elixir, :logger]
       ]}
    )

    included = Enum.flat_map(applications, fn {_, spec} -> spec.included end)

    apps =
      applications
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {app, spec} ->
        {app, String.to_charlist(spec.version), if(app in included, do: :load, else: :permanent)}
      end)

    releases = Path.join(rel, "releases")
    File.mkdir_p!(releases)
    base = Path.join(releases, "start")

    write_term!(
      base <> ".rel",
      {:release, {String.to_charlist(config.name), String.to_charlist(config.version)},
       {:erts, :erlang.system_info(:version)}, apps ++ [{:pocket_runtime, ~c"0.1.0"}]}
    )

    paths = Path.wildcard(Path.join([rel, "lib", "*", "ebin"])) |> Enum.map(&String.to_charlist/1)

    case :systools.make_script(String.to_charlist(base), [{:path, paths}, :silent, :no_warn_sasl]) do
      {:ok, _, []} -> :ok
      {:ok, _, warnings} -> Mix.raise("Release boot warnings: #{inspect(warnings)}")
      error -> Mix.raise("Cannot generate boot script: #{inspect(error)}")
    end

    # Use the exact configuration Mix compiled against (including imports and
    # custom config_path), rather than evaluating configuration a second time.
    env = Mix.Tasks.Loadconfig.read_compile()
    env = Enum.filter(env, fn {app, _} -> Map.has_key?(applications, app) end)
    env = Keyword.put(env, :pocket_runtime, main: config.main)
    write_term!(Path.join(releases, "sys.config"), env)
    disk_entries(rel)
  end

  defp boot_comment(config) do
    Enum.join(
      [
        "erlaotc #{:erlang.system_info(:version)}",
        "-S",
        "1:1",
        "-fnu",
        "-Bd",
        "--",
        "-root",
        "$ROOT",
        "-bindir",
        "$ROOT/bin",
        "-progname",
        "$ROOT",
        "-primary_archive",
        "$ROOT",
        "-boot",
        "$ROOT/releases/start",
        "-config",
        "$ROOT/releases/sys",
        "-noshell",
        "-shutdown_time",
        to_string(config.shutdown_timeout),
        "-s",
        "Elixir.Pocket.Runtime",
        "main"
      ],
      "\n"
    ) <> "\n"
  end

  defp check_priv!(app, dir) do
    # Standard runtime files came from the verified toolchain; native OTP
    # components were linked by its builder. Third-party assets need explicit
    # filesystem semantics, which v0.1 intentionally doesn't pretend to support.
    {:ok, [[archive]]} = :init.get_argument(:primary_archive)

    unless String.starts_with?(dir, to_string(archive) <> "/") do
      priv = Path.join(dir, "priv")

      case :erl_prim_loader.list_dir(String.to_charlist(priv)) do
        {:ok, []} ->
          :ok

        {:ok, _} ->
          Mix.raise(
            "#{app} contains priv/ assets or native libraries. Pocket v0.1 cannot package these without extraction."
          )

        :error ->
          :ok

        {:error, _} ->
          :ok
      end
    end
  end

  defp copy_tree!(source, destination) do
    File.mkdir_p!(destination)
    {:ok, names} = :erl_prim_loader.list_dir(String.to_charlist(source))

    for name <- names do
      name = to_string(name)

      if Path.extname(name) in @native_extensions,
        do: Mix.raise("Unsupported native library: #{source}/#{name}")

      bytes = read!(Path.join(source, name))
      File.write!(Path.join(destination, name), bytes)
    end
  end

  defp read!(path) do
    case :erl_prim_loader.get_file(String.to_charlist(path)) do
      {:ok, bytes, _} -> bytes
      other -> Mix.raise("Cannot read #{path}: #{inspect(other)}")
    end
  end

  defp consult!(path) do
    {:ok, tokens, _} = path |> read!() |> String.to_charlist() |> :erl_scan.string()
    {:ok, term} = :erl_parse.parse_term(tokens)
    term
  end

  defp write_term!(path, term), do: File.write!(path, :io_lib.format(~c"~tp.~n", [term]))

  defp disk_entries(root) do
    for path <- Path.wildcard(Path.join(root, "**"), match_dot: true),
        File.regular?(path),
        do: {Path.relative_to(path, root), File.read!(path)}
  end

  defp write_executable!(path, emulator, entries, comment) do
    File.write!(path, Pocket.Archive.executable(emulator, entries, comment), [:exclusive])
    File.chmod!(path, 0o755)
  end
end
