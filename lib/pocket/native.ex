defmodule Pocket.Native do
  @moduledoc false

  # Each adapter names a reviewed package version and its Rustler entry point.
  # Link the selected archive before AOT. Independent Rustler staticlibs export
  # the same primary nif_init symbol, so combinations need their own integration.
  @versions [gpui_native: "0.2.0", tailscale: "0.6.1"]

  def build!(applications, toolchain, workspace) do
    selected =
      for {app, version} <- @versions, spec = applications[app] do
        unless spec.version == version,
          do: Mix.raise("Pocket's static adapter supports #{app} #{version}, not #{spec.version}")

        app
      end

    if selected == [] do
      {toolchain |> File.read!() |> Pocket.Archive.emulator!(), []}
    else
      if length(selected) > 1 do
        Mix.raise(
          "Combining multiple Rustler NIF adapters is not supported yet; " <>
            "their primary nif_init symbols and registrations must be isolated"
        )
      end

      sdk =
        System.get_env("POCKET_NATIVE_SDK") ||
          Mix.raise(
            "Static NIFs need a relinkable native SDK. Pass --native-sdk PATH; " <>
              "the bootstrap toolchain does not ship one yet."
          )

      Pocket.Compiler.verify_sdk!(sdk)
      {nifs, libraries} = Enum.map(selected, &build_adapter!(&1, sdk)) |> Enum.unzip()
      link!(toolchain, sdk, workspace, nifs, List.flatten(libraries))
    end
  end

  def linked_file?(:gpui_native, path, native) do
    Enum.any?(native, &(&1["module"] == "Elixir.GPUI.Native.NIF")) and
      Regex.match?(~r{\Anative/(?:lib)?gpui_nif[^/]*\.(?:so|dylib)\z}, path)
  end

  def linked_file?(:tailscale, path, native) do
    Enum.any?(native, &(&1["module"] == "Elixir.Tailscale.Native")) and
      Regex.match?(~r{\Anative/(?:lib)?ts_elixir\.(?:so|dylib)\z}, path)
  end

  def linked_file?(_, _, _), do: false

  defp build_adapter!(:gpui_native, sdk) do
    if System.get_env("ZED_HEADLESS") == "1" or
         not (Code.ensure_loaded?(GPUI.Native.NIF) and
                apply(GPUI.Native.NIF, :compiled?, [])) do
      Mix.raise(
        "Static GPUI builds require the native desktop host; unset GPUI_SKIP_NATIVE/ZED_HEADLESS"
      )
    end

    source = Mix.Project.deps_paths() |> Map.fetch!(:gpui_native) |> Path.join("native")

    host =
      case System.get_env("GPUI_NATIVE_HOST") do
        nil -> Application.get_env(:gpui_native, GPUI.Native, [])[:host] || :vanilla
        "vanilla" -> :vanilla
        "gpui_component" -> :gpui_component
        other -> Mix.raise("Unsupported GPUI_NATIVE_HOST: #{inspect(other)}")
      end

    feature =
      case host do
        :vanilla -> "vanilla-host"
        :gpui_component -> "gpui-component-host"
        other -> Mix.raise("Unsupported GPUI host: #{inspect(other)}")
      end

    {nif, libs} =
      build_rust!(source, sdk, "gpui", "gpui_nif", "gpui_native", "Elixir.GPUI.Native.NIF", [
        "--no-default-features",
        "--features",
        feature
      ])

    {Map.put(nif, "host", to_string(host)), libs}
  end

  defp build_adapter!(:tailscale, sdk) do
    source = Mix.Project.deps_paths() |> Map.fetch!(:tailscale) |> Path.join("native/ts_elixir")
    build_rust!(source, sdk, "tailscale", "ts_elixir", "tailscale", "Elixir.Tailscale.Native", [])
  end

  defp build_rust!(source, sdk, id, crate, app, module, features) do
    cargo = System.find_executable("cargo") || Mix.raise("Static NIF builds require Rust/Cargo")
    target = Path.join(Mix.Project.build_path(), "pocket-native/#{id}")
    lock = Path.expand("pocket.#{id}.lock")

    # Hex packages need not ship Cargo.lock. Keep a project-owned, reviewable
    # graph for the static artifact, independent of mutable Cargo resolution.
    if File.exists?(lock) do
      File.cp!(lock, Path.join(source, "Cargo.lock"))
    else
      unless File.exists?(Path.join(source, "Cargo.lock")) do
        {log, status} =
          System.cmd(cargo, ["generate-lockfile"], cd: source, stderr_to_stdout: true)

        if status != 0, do: Mix.raise("Cannot resolve #{id}'s Rust dependency graph:\n#{log}")
      end

      File.cp!(Path.join(source, "Cargo.lock"), lock)
      Mix.shell().info("Created pocket.#{id}.lock; review and commit the Rust dependency graph")
    end

    Mix.shell().info("Building #{id} static archive")

    {log, status} =
      System.cmd(
        cargo,
        [
          "rustc",
          "--locked",
          "--manifest-path",
          Path.join(source, "Cargo.toml"),
          "--release",
          "--lib",
          "--crate-type",
          "staticlib",
          "--target-dir",
          target
        ] ++ features ++ ["--", "--print=native-static-libs"],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("#{id} static compilation failed:\n#{log}")

    libs =
      case Regex.run(~r/^note: native-static-libs: (.+)$/m, log) do
        [_, flags] -> OptionParser.split(flags)
        _ -> Mix.raise("Rust did not report #{id}'s native link requirements")
      end

    archive = Path.join(target, "release/lib#{crate}.a")

    nif = %{
      "app" => app,
      "module" => module,
      "init" => "#{crate}_nif_init",
      "archive" => archive,
      "sha256" => Pocket.Toolchain.digest(archive),
      "cargo_lock_sha256" => Pocket.Toolchain.digest(lock),
      "sdk_sha256" => Pocket.Toolchain.digest(Path.join(sdk, "sdk.json"))
    }

    {nif, libs}
  end

  defp link!(toolchain, sdk, workspace, nifs, libs) do
    descriptor = Path.join(workspace, "native.json")
    File.write!(descriptor, JSON.encode!(%{"schema" => 1, "nifs" => nifs, "link_args" => libs}))
    emulator = Path.join(workspace, "beam.smp")

    {log, status} =
      System.cmd(
        toolchain,
        ["run", Path.join(sdk, "link.exs"), sdk, descriptor, emulator],
        env: Pocket.Toolchain.clean_env(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Native runtime linking failed:\n#{log}")
    {File.read!(emulator), Enum.map(nifs, &Map.delete(&1, "archive"))}
  end
end
