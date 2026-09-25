defmodule Pocket.Native do
  @moduledoc false

  # First adapter: GPUI's published Rust sources and named Rustler NIF entry.
  # Keep the version boundary explicit; a new release needs a reviewed adapter.
  def build!(applications, toolchain, workspace) do
    case applications[:gpui_native] do
      nil ->
        {toolchain |> File.read!() |> Pocket.Archive.emulator!(), []}

      %{version: "0.2.0"} ->
        build_gpui!(toolchain, workspace)

      %{version: version} ->
        Mix.raise("Pocket's static GPUI adapter supports gpui_native 0.2.0, not #{version}")
    end
  end

  def linked_file?(:gpui_native, path, native) do
    Enum.any?(native, &(&1["module"] == "Elixir.GPUI.Native.NIF")) and
      Regex.match?(~r{\Anative/(?:lib)?gpui_nif[^/]*\.(?:so|dylib)\z}, path)
  end

  def linked_file?(_, _, _), do: false

  defp build_gpui!(toolchain, workspace) do
    sdk =
      System.get_env("POCKET_NATIVE_SDK") ||
        Mix.raise(
          "GPUI needs a relinkable native SDK. The bootstrap toolchain does not ship one yet. " <>
            "Export an SDK from elixiraotc and pass --native-sdk PATH; see examples/gpui/README.md."
        )

    Pocket.Compiler.verify_sdk!(sdk)

    if System.get_env("ZED_HEADLESS") == "1" or
         not (Code.ensure_loaded?(GPUI.Native.NIF) and
                apply(GPUI.Native.NIF, :compiled?, [])) do
      Mix.raise(
        "Static GPUI builds require the native desktop host; unset GPUI_SKIP_NATIVE/ZED_HEADLESS"
      )
    end

    source = Mix.Project.deps_paths() |> Map.fetch!(:gpui_native) |> Path.join("native")
    target = Path.join(Mix.Project.build_path(), "pocket-native/gpui")
    lock = Path.expand("pocket.gpui.lock")
    cargo = System.find_executable("cargo") || Mix.raise("Static GPUI builds require Rust/Cargo")

    # GPUI's Hex package does not contain Cargo.lock. Preserve a reviewable
    # project lock instead of resolving Zed's mutable branch on each clean build.
    if File.exists?(lock) do
      File.cp!(lock, Path.join(source, "Cargo.lock"))
    else
      unless File.exists?(Path.join(source, "Cargo.lock")) do
        {log, status} =
          System.cmd(cargo, ["generate-lockfile"], cd: source, stderr_to_stdout: true)

        if status != 0, do: Mix.raise("Cannot resolve GPUI's Rust dependency graph:\n#{log}")
      end

      File.cp!(Path.join(source, "Cargo.lock"), lock)
      Mix.shell().info("Created pocket.gpui.lock; review and commit the Rust dependency graph")
    end

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

    Mix.shell().info("Building GPUI static archive (#{feature})")

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
          "--no-default-features",
          "--features",
          feature,
          "--crate-type",
          "staticlib",
          "--target-dir",
          target,
          "--",
          "--print=native-static-libs"
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("GPUI static compilation failed:\n#{log}")

    libs =
      case Regex.run(~r/^note: native-static-libs: (.+)$/m, log) do
        [_, flags] -> OptionParser.split(flags)
        _ -> Mix.raise("Rust did not report the GPUI static library's native link requirements")
      end

    archive = Path.join(target, "release/libgpui_nif.a")

    nif = %{
      "app" => "gpui_native",
      "module" => "Elixir.GPUI.Native.NIF",
      "init" => "gpui_nif_nif_init",
      "archive" => archive,
      "sha256" => Pocket.Toolchain.digest(archive),
      "host" => to_string(host),
      "cargo_lock_sha256" => Pocket.Toolchain.digest(lock),
      "sdk_sha256" => Pocket.Toolchain.digest(Path.join(sdk, "sdk.json"))
    }

    descriptor = Path.join(workspace, "native.json")
    File.write!(descriptor, JSON.encode!(%{"schema" => 1, "nifs" => [nif], "link_args" => libs}))
    emulator = Path.join(workspace, "beam.smp")

    {log, status} =
      System.cmd(
        toolchain,
        ["run", Path.join(sdk, "link.exs"), sdk, descriptor, emulator],
        env: Pocket.Toolchain.clean_env(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Native runtime linking failed:\n#{log}")
    {File.read!(emulator), [Map.delete(nif, "archive")]}
  end
end
