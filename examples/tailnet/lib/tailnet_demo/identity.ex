defmodule TailnetDemo.Identity do
  @moduledoc false
  import Bitwise

  def connect(role, opts) do
    directory =
      opts[:state_dir] ||
        Path.join(to_string(:filename.basedir(:user_data, ~c"pocket-tailnet-demo")), role)

    directory = Path.expand(directory)
    prepare!(directory)
    key_file = Path.join(directory, "keys.json")
    check_key_file!(key_file)
    auth_key = System.get_env("TS_AUTHKEY")
    System.delete_env("TS_AUTHKEY")
    options = [hostname: opts[:hostname] || "pocket-demo-#{role}"]
    options = if auth_key, do: Keyword.put(options, :auth_key, auth_key), else: options
    result = Tailscale.connect(key_file, options)
    if File.regular?(key_file), do: File.chmod!(key_file, 0o600)
    result
  end

  def prepare!(directory) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        File.mkdir_p!(directory)
        File.chmod!(directory, 0o700)

      {:ok, %{type: :directory, mode: mode}} when (mode &&& 0o077) == 0 ->
        :ok

      _ ->
        raise ArgumentError,
              "state directory must be a private directory (mode 0700), not a symlink"
    end
  end

  defp check_key_file!(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular, mode: mode}} when (mode &&& 0o077) == 0 -> :ok
      _ -> raise ArgumentError, "identity key file must be a private regular file (mode 0600)"
    end
  end
end
