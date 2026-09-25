defmodule Pocket.Compiler do
  @moduledoc false

  # Compilation can require filesystem-only OTP interfaces (epp, Record).
  # Materialize the verified build inputs, never the deployed executable.
  def prepare!(build_path) do
    if sdk = System.get_env("POCKET_NATIVE_SDK") do
      verify_sdk!(sdk)
      {:ok, [[archive]]} = :init.get_argument(:primary_archive)
      prefix = to_string(archive) <> "/"
      root = Path.join(build_path, "compiler")

      directories =
        for path <- :code.get_path(),
            path = to_string(path),
            String.starts_with?(path, prefix) do
          app_dir = Path.dirname(path)
          name = Path.basename(app_dir)
          target = Path.join([root, "lib", name])
          copy_archive!(app_dir, target)
          include = Path.join([sdk, "include", name, "include"])
          if File.dir?(include), do: File.cp_r!(include, Path.join(target, "include"))

          for appfile <- Path.wildcard(Path.join(target, "ebin/*.app")) do
            app = appfile |> Path.basename(".app") |> String.to_atom()
            true = :code.replace_path(app, String.to_charlist(Path.join(target, "ebin")))
          end

          target
        end

      :persistent_term.put({__MODULE__, :builtin_directories}, MapSet.new(directories))
    end
  end

  def builtin_directory?(path) do
    :persistent_term.get({__MODULE__, :builtin_directories}, MapSet.new())
    |> MapSet.member?(path)
  end

  def verify_sdk!(sdk) do
    manifest = sdk |> Path.join("sdk.json") |> File.read!() |> JSON.decode!()
    version = to_string(:erlang.system_info(:version))

    unless manifest["schema"] == 1 and manifest["erts"] == version do
      Mix.raise("Native SDK must match the pinned ERTS #{version}")
    end

    unless target_family(manifest["target"]) ==
             target_family(to_string(:erlang.system_info(:system_architecture))) do
      Mix.raise("Native SDK target #{inspect(manifest["target"])} does not match this machine")
    end

    # This is explicitly selected, trusted local build input. Its self-inventory
    # detects corruption; it is not a substitute for a published artifact pin.
    for {path, expected} <- manifest["files"] do
      if Path.type(path) != :relative or ".." in Path.split(path),
        do: Mix.raise("Unsafe native SDK path: #{path}")

      actual =
        Path.join(sdk, path)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      unless actual == expected, do: Mix.raise("Native SDK digest mismatch: #{path}")
    end

    required =
      ["link.exs", "driver_tab.i"] ++
        for "$SDK/" <> path <- manifest["link_args"], do: path

    for path <- required do
      unless Map.has_key?(manifest["files"], path),
        do: Mix.raise("Native SDK does not inventory #{path}")
    end

    manifest
  end

  defp target_family(target) when is_binary(target) do
    cpu = target |> String.split("-") |> List.first()

    os =
      cond do
        String.contains?(target, "-darwin") -> :darwin
        String.contains?(target, "-linux") -> :linux
        true -> Mix.raise("Unsupported native SDK target: #{target}")
      end

    {cpu, os}
  end

  defp target_family(_), do: Mix.raise("Native SDK is missing its target")

  defp copy_archive!(source, target) do
    case :erl_prim_loader.list_dir(String.to_charlist(source)) do
      {:ok, names} ->
        File.mkdir_p!(target)

        for name <- names do
          name = to_string(name)
          copy_archive!(Path.join(source, name), Path.join(target, name))
        end

      _ ->
        {:ok, bytes, _} = :erl_prim_loader.get_file(String.to_charlist(source))
        File.write!(target, bytes)
    end
  end
end
