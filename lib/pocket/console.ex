defmodule Pocket.Console do
  @moduledoc """
  Opt-in, local-only IEx and diagnostics for long-running Pocket executables.

  Set `pocket: [main: MyApp.CLI, console: true]`. Normal invocations open a
  private local socket; `my-app --console` attaches without starting a second
  application. `--status`, `--observe`, and `--stop` use the same connection.

  The default location is `<user-cache>/pocket/<executable-name>`. Set
  `POCKET_CONSOLE_DIR` on both invocations, or pass a directory to a client
  command, to select a different instance. An existing directory is never
  overwritten, even if stale. Orderly shutdown removes the socket directory.

  Console access allows arbitrary code execution as the service's OS user.
  No TCP listener or BEAM distribution is enabled. EOF/Ctrl-D detaches without
  stopping the service; Ctrl-C kills the client. The session is line-oriented:
  no completion, terminal job control, or global stderr/Logger forwarding.
  """
  use Supervisor
  import Bitwise

  @doc "Starts a console supervisor. Pocket's console-enabled runtime calls this automatically."
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    {:ok, _} = Application.ensure_all_started(:iex)

    Supervisor.init(
      [
        {Task.Supervisor, name: Pocket.Console.Sessions, max_children: 16},
        {Pocket.Console.Server, Keyword.fetch!(options, :directory)}
      ],
      strategy: :one_for_all
    )
  end

  @doc "Returns the local instance directory, respecting `POCKET_CONSOLE_DIR`."
  def directory do
    System.get_env("POCKET_CONSOLE_DIR") ||
      Path.join(
        to_string(:filename.basedir(:user_cache, ~c"pocket")),
        Application.fetch_env!(:pocket_runtime, :name)
      )
  end

  @doc false
  def command([command]) when command in ["--console", "--status", "--observe", "--stop"],
    do: command([command, directory()])

  def command([command, directory])
      when command in ["--console", "--status", "--observe", "--stop"] do
    directory = Path.expand(directory)

    case File.lstat(directory) do
      {:ok, %{type: :directory, mode: mode}} when (mode &&& 0o077) == 0 ->
        connect(command, Path.join(directory, "control.sock"))

      _ ->
        IO.puts(:stderr, "No private console directory at #{directory}; start the service first.")
        {:error, 1}
    end
  end

  def command([command | _]) when command in ["--console", "--status", "--observe", "--stop"] do
    IO.puts(:stderr, "usage: #{command} [SOCKET_DIRECTORY]")
    {:error, 2}
  end

  def command(_), do: :not_console

  defp connect(command, path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 2_000) do
      {:ok, socket} ->
        try do
          :ok = :gen_tcp.send(socket, command <> "\n")
          reader = if command == "--console", do: spawn(fn -> input(socket) end)

          try do
            output(socket)
          after
            if reader, do: Process.exit(reader, :kill)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Cannot connect to #{path}: #{:inet.format_error(reason)}")
        {:error, 1}
    end
  end

  defp input(socket) do
    case IO.gets("") do
      data when is_binary(data) ->
        data = if String.ends_with?(data, "\n"), do: data, else: data <> "\n"

        case :gen_tcp.send(socket, data) do
          :ok -> input(socket)
          {:error, _} -> :ok
        end

      _ ->
        :gen_tcp.shutdown(socket, :write)
    end
  end

  defp output(socket, pending \\ "") do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        # A socket read can split a UTF-8 character between packets.
        case :unicode.characters_to_binary(pending <> data, :utf8, :utf8) do
          text when is_binary(text) ->
            IO.write(text)
            output(socket)

          {:incomplete, text, rest} ->
            IO.write(text)
            output(socket, rest)

          {:error, _, _} ->
            IO.puts(:stderr, "Console sent invalid UTF-8")
            {:error, 1}
        end

      {:error, :closed} when pending == "" ->
        :ok

      {:error, :closed} ->
        IO.puts(:stderr, "Console closed during a UTF-8 character")
        {:error, 1}

      {:error, reason} ->
        IO.puts(:stderr, "Connection failed: #{:inet.format_error(reason)}")
        {:error, 1}
    end
  end
end
