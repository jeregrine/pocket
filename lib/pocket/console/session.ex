defmodule Pocket.Console.Session do
  @moduledoc false

  # An IO device for a real IEx session. Parsing/evaluation stay in the target;
  # the client never sends Erlang terms or executable IO requests.
  def run(socket) do
    run(
      socket,
      fn bytes -> :gen_tcp.send(socket, bytes) end,
      fn -> :inet.setopts(socket, active: :once) end
    )
  end

  # Transport adapter hook. The caller authenticates before starting a session.
  # write receives UTF-8 output. request_line asks the adapter to deliver a line
  # or EOF as {:pocket_console_input, channel_id, binary | :eof}.
  # Keep writes synchronous so a slow client applies backpressure to IEx.
  def run(channel_id, write, request_line)
      when is_function(write, 1) and is_function(request_line, 0) do
    channel = %{id: channel_id, write: write, request_line: request_line}
    device = self()
    Process.flag(:trap_exit, true)

    shell =
      spawn_link(fn ->
        Process.group_leader(self(), device)
        IEx.Server.run(register: false, on_eof: :stop_evaluator, dot_iex: "")
      end)

    try do
      loop(channel, shell)
    after
      # IEx stops its evaluator when the group leader exits.
      Process.exit(shell, :shutdown)
    end
  end

  defp loop(channel, shell) do
    receive do
      {:io_request, from, ref, request} ->
        send(from, {:io_reply, ref, request(channel, request)})
        loop(channel, shell)

      {:EXIT, ^shell, _} ->
        :ok

      {:EXIT, _supervisor, reason} ->
        exit(reason)
    end
  end

  defp request(channel, {:put_chars, encoding, chars}),
    do: channel.write.(:unicode.characters_to_binary(chars, encoding))

  defp request(channel, {:put_chars, encoding, module, function, args}),
    do: request(channel, {:put_chars, encoding, apply(module, function, args)})

  defp request(channel, {:get_until, encoding, prompt, module, function, args}) do
    :ok = request(channel, {:put_chars, :unicode, prompt})
    get_until(channel, encoding, module, function, args, [])
  end

  defp request(channel, {:get_line, encoding, prompt}) do
    :ok = request(channel, {:put_chars, :unicode, prompt})
    line(channel, encoding)
  end

  defp request(_channel, {:setopts, options}) do
    if Enum.all?(options, fn
         {:expand_fun, fun} when is_function(fun, 1) -> true
         {:encoding, :unicode} -> true
         {:binary, false} -> true
         _ -> false
       end),
       do: :ok,
       else: {:error, :enotsup}
  end

  defp request(channel, {:requests, requests}) do
    Enum.reduce_while(requests, :ok, fn request, _ ->
      case request(channel, request) do
        {:error, _} = error -> {:halt, error}
        result -> {:cont, result}
      end
    end)
  end

  defp request(_channel, :getopts), do: [binary: false, encoding: :unicode]
  defp request(_channel, {:get_geometry, _}), do: {:error, :enotsup}
  defp request(_channel, _), do: {:error, :request}

  defp get_until(channel, encoding, module, function, args, continuation) do
    case apply(module, function, [continuation, line(channel, encoding) | args]) do
      {:done, result, rest} ->
        if rest != :eof do
          Process.put(:pocket_console_buffer, :unicode.characters_to_binary(rest, encoding))
        end

        result

      {:more, continuation} ->
        get_until(channel, encoding, module, function, args, continuation)
    end
  end

  defp line(channel, encoding) do
    case Process.delete(:pocket_console_buffer) do
      data when is_binary(data) and data != "" ->
        :unicode.characters_to_list(data, encoding)

      _ ->
        if Process.get(:pocket_console_eof, false) do
          :eof
        else
          :ok = channel.request_line.()
          await_line(channel, encoding)
        end
    end
  end

  defp await_line(channel, encoding) do
    channel_id = channel.id

    receive do
      {kind, ^channel_id, data} when kind in [:tcp, :pocket_console_input] and is_binary(data) ->
        :unicode.characters_to_list(data, encoding)

      {:pocket_console_input, ^channel_id, :eof} ->
        Process.put(:pocket_console_eof, true)
        :eof

      {:tcp_closed, ^channel_id} ->
        Process.put(:pocket_console_eof, true)
        :eof

      {:tcp_error, ^channel_id, reason} ->
        exit({:socket, reason})

      # Keep background IO and orderly supervision shutdown responsive while
      # IEx is waiting for the next input line.
      {:io_request, from, ref, request} ->
        send(from, {:io_reply, ref, request(channel, request)})
        await_line(channel, encoding)

      {:EXIT, _pid, reason} ->
        exit(reason)
    end
  end
end
