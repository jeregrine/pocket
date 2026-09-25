defmodule Pocket.Console.Server do
  @moduledoc false
  use GenServer

  def start_link(directory), do: GenServer.start_link(__MODULE__, directory)

  @impl true
  def init(directory) do
    Process.flag(:trap_exit, true)
    directory = Path.expand(directory)
    path = Path.join(directory, "control.sock")

    if byte_size(path) > 103 do
      raise ArgumentError,
            "console socket path is too long; set POCKET_CONSOLE_DIR to a shorter path"
    end

    File.mkdir_p!(Path.dirname(directory))
    # Never reuse directories or unlink somebody else's socket, even if stale.
    File.mkdir!(directory)

    try do
      File.chmod!(directory, 0o700)

      {:ok, listener} =
        :gen_tcp.listen(0,
          ifaddr: {:local, path},
          active: false,
          mode: :binary,
          packet: :line,
          packet_size: 65_536,
          exit_on_close: false,
          send_timeout: 5_000,
          send_timeout_close: true
        )

      acceptor = spawn_link(fn -> accept(listener) end)
      {:ok, %{listener: listener, acceptor: acceptor, directory: directory, path: path}}
    rescue
      error ->
        File.rm(path)
        File.rmdir(directory)
        reraise error, __STACKTRACE__
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, {:acceptor_exited, reason}, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.path)
    File.rmdir(state.directory)
  end

  defp accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case Task.Supervisor.start_child(Pocket.Console.Sessions, fn ->
               receive do
                 {:socket, socket} ->
                   try do
                     dispatch(socket)
                   after
                     :gen_tcp.close(socket)
                   end
               end
             end) do
          {:ok, pid} ->
            :ok = :gen_tcp.controlling_process(socket, pid)
            send(pid, {:socket, socket})

          {:error, :max_children} ->
            :gen_tcp.close(socket)
        end

        accept(listener)

      {:error, :closed} ->
        :ok
    end
  end

  defp dispatch(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "--console\n"} ->
        Pocket.Console.Session.run(socket)

      {:ok, "--status\n"} ->
        :gen_tcp.send(socket, JSON.encode!(status()) <> "\n")

      {:ok, "--observe\n"} ->
        :gen_tcp.send(socket, observe())

      {:ok, "--stop\n"} ->
        :gen_tcp.send(socket, "stopping\n")
        :init.stop(0)

      _ ->
        :gen_tcp.send(socket, "unknown command\n")
    end
  end

  defp status do
    %{
      os_pid: System.pid(),
      node: to_string(node()),
      processes: :erlang.system_info(:process_count),
      memory_bytes: :erlang.memory(:total),
      applications:
        Application.started_applications()
        |> Enum.map(fn {app, _, version} ->
          %{name: to_string(app), version: to_string(version)}
        end)
        |> Enum.sort_by(& &1.name)
    }
  end

  defp observe do
    rows =
      Process.list()
      |> Enum.flat_map(fn pid ->
        case Process.info(pid, [:registered_name, :memory, :reductions, :message_queue_len]) do
          nil -> []
          info -> [{pid, info}]
        end
      end)
      |> Enum.sort_by(fn {_, info} -> info[:memory] end, :desc)
      |> Enum.take(15)
      |> Enum.map(fn {pid, info} ->
        "#{inspect(pid)}\t#{info[:memory]}\t#{info[:reductions]}\t" <>
          "#{info[:message_queue_len]}\t#{inspect(info[:registered_name])}\n"
      end)

    ["PID\tMEMORY_BYTES\tREDUCTIONS\tMAILBOX\tNAME\n", rows]
  end
end
