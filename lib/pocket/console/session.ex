defmodule Pocket.Console.Session do
  @moduledoc false

  # An IO device for a real IEx session. Parsing/evaluation stay in the target;
  # the client never sends Erlang terms or executable IO requests.
  def run(socket) do
    device = self()
    Process.flag(:trap_exit, true)

    shell =
      spawn_link(fn ->
        Process.group_leader(self(), device)
        IEx.Server.run(register: false, on_eof: :stop_evaluator, dot_iex: "")
      end)

    try do
      loop(socket, shell)
    after
      # IEx stops its evaluator when the group leader exits.
      Process.exit(shell, :shutdown)
    end
  end

  defp loop(socket, shell) do
    receive do
      {:io_request, from, ref, request} ->
        send(from, {:io_reply, ref, request(socket, request)})
        loop(socket, shell)

      {:EXIT, ^shell, _} ->
        :ok

      {:EXIT, _supervisor, reason} ->
        exit(reason)
    end
  end

  defp request(socket, {:put_chars, encoding, chars}),
    do: :gen_tcp.send(socket, :unicode.characters_to_binary(chars, encoding))

  defp request(socket, {:put_chars, encoding, module, function, args}),
    do: request(socket, {:put_chars, encoding, apply(module, function, args)})

  defp request(socket, {:get_until, encoding, prompt, module, function, args}) do
    :ok = request(socket, {:put_chars, :unicode, prompt})
    get_until(socket, encoding, module, function, args, [])
  end

  defp request(socket, {:get_line, encoding, prompt}) do
    :ok = request(socket, {:put_chars, :unicode, prompt})
    line(socket, encoding)
  end

  defp request(_socket, {:setopts, options}) do
    if Enum.all?(options, fn
         {:expand_fun, fun} when is_function(fun, 1) -> true
         {:encoding, :unicode} -> true
         {:binary, false} -> true
         _ -> false
       end),
       do: :ok,
       else: {:error, :enotsup}
  end

  defp request(socket, {:requests, requests}) do
    Enum.reduce_while(requests, :ok, fn request, _ ->
      case request(socket, request) do
        {:error, _} = error -> {:halt, error}
        result -> {:cont, result}
      end
    end)
  end

  defp request(_socket, :getopts), do: [binary: false, encoding: :unicode]
  defp request(_socket, {:get_geometry, _}), do: {:error, :enotsup}
  defp request(_socket, _), do: {:error, :request}

  defp get_until(socket, encoding, module, function, args, continuation) do
    case apply(module, function, [continuation, line(socket, encoding) | args]) do
      {:done, result, rest} ->
        if rest != :eof do
          Process.put(:pocket_console_buffer, :unicode.characters_to_binary(rest, encoding))
        end

        result

      {:more, continuation} ->
        get_until(socket, encoding, module, function, args, continuation)
    end
  end

  defp line(socket, encoding) do
    case Process.delete(:pocket_console_buffer) do
      data when is_binary(data) and data != "" ->
        :unicode.characters_to_list(data, encoding)

      _ ->
        if Process.get(:pocket_console_eof, false) do
          :eof
        else
          :ok = :inet.setopts(socket, active: :once)
          await_line(socket, encoding)
        end
    end
  end

  defp await_line(socket, encoding) do
    receive do
      {:tcp, ^socket, data} ->
        :unicode.characters_to_list(data, encoding)

      {:tcp_closed, ^socket} ->
        Process.put(:pocket_console_eof, true)
        :eof

      {:tcp_error, ^socket, reason} ->
        exit({:socket, reason})

      # Keep background IO and orderly supervision shutdown responsive while
      # IEx is waiting for the next input line.
      {:io_request, from, ref, request} ->
        send(from, {:io_reply, ref, request(socket, request)})
        await_line(socket, encoding)

      {:EXIT, _pid, reason} ->
        exit(reason)
    end
  end
end
