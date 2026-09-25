defmodule Pocket.Toolchain do
  @moduledoc false

  # Promotion is a reviewed source change, never a mutable "latest" download.
  @external_resource Path.expand("../../priv/toolchain.json", __DIR__)
  @manifest @external_resource |> File.read!() |> JSON.decode!()

  def target do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        other -> Mix.raise("Pocket does not support #{inspect(other)} yet")
      end

    arch = to_string(:erlang.system_info(:system_architecture))

    cpu =
      cond do
        String.starts_with?(arch, ["aarch64", "arm64"]) -> "arm64"
        String.starts_with?(arch, "x86_64") -> "x86_64"
        true -> Mix.raise("Pocket does not support architecture #{arch}")
      end

    "#{os}-#{cpu}"
  end

  def manifest, do: @manifest

  def lock!(path \\ "pocket.lock") do
    expected = manifest()

    case File.read(path) do
      {:ok, contents} ->
        unless JSON.decode!(contents) == expected do
          Mix.raise(
            "#{path} does not match this Pocket version's reviewed toolchain manifest. " <>
              "Update Pocket and its lock together; arbitrary download URLs are not accepted."
          )
        end

      {:error, :enoent} ->
        File.write!(path, JSON.encode!(expected) <> "\n", [:exclusive])

      {:error, reason} ->
        Mix.raise("Cannot read #{path}: #{:file.format_error(reason)}")
    end

    expected
  end

  def ensure!(opts \\ []) do
    manifest = lock!()
    target = target()
    artifact = Map.fetch!(manifest["artifacts"], target)
    dir = Path.expand(Path.join(".pocket/toolchains", manifest["id"]))
    path = Path.join(dir, "elixiraotc-#{target}")
    File.mkdir_p!(dir)

    unless File.regular?(path) do
      if opts[:offline] do
        Mix.raise("Toolchain is not cached. Run mix pocket.toolchain before an offline build.")
      end

      unless opts[:install] do
        Mix.raise(
          "Pocket needs the experimental #{manifest["id"]} toolchain for #{target}.\n" <>
            "Run mix pocket.toolchain to download and verify it, then retry.\n" <>
            "Or explicitly allow installation with mix pocket.build --install."
        )
      end

      download!(artifact, path)
    end

    verify!(path, artifact["sha256"])
    File.chmod!(path, 0o755)
    {path, manifest}
  end

  def verify!(path, expected) do
    actual = digest(path)

    unless actual == expected do
      Mix.raise(
        "SHA-256 mismatch for #{path}; refusing to execute it.\n" <>
          "Expected: #{expected}\nActual:   #{actual}\n" <>
          "Remove the corrupt cached file explicitly before reinstalling."
      )
    end

    :ok
  end

  def digest(path) do
    path
    |> File.stream!(1024 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def clean_env do
    for key <- ~w(ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ERL_LIBS ELIXIR_ERL_OPTIONS),
        do: {key, nil}
  end

  defp download!(artifact, path) do
    curl = System.find_executable("curl") || Mix.raise("Install curl to fetch the toolchain")
    tmp = path <> ".download-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
    Mix.shell().info("Downloading pinned toolchain from #{artifact["url"]}")

    try do
      {_, status} =
        System.cmd(
          curl,
          [
            "--fail",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            "--connect-timeout",
            "30",
            "--max-time",
            "600",
            "--output",
            tmp,
            artifact["url"]
          ],
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("Toolchain download failed (curl exit #{status})")
      verify!(tmp, artifact["sha256"])
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end
  end
end
