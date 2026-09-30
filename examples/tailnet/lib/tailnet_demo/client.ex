defmodule TailnetDemo.Client do
  @moduledoc false
  alias TailnetDemo.Wire

  def request(transport, device, peer, port, token, command, fields \\ %{}) do
    with {:ok, socket} <- transport.connect(device, peer, port) do
      try do
        message = Map.merge(fields, %{"version" => 1, "token" => token, "command" => command})

        with :ok <- Wire.send(transport, socket, message),
             {:ok, response, _rest} <- Wire.recv(transport, socket) do
          case response do
            %{"type" => "result", "value" => value} -> {:ok, value}
            %{"type" => "error", "message" => message} -> {:error, message}
            _ -> {:error, :unexpected_response}
          end
        end
      after
        transport.close(socket)
      end
    end
  end

  def console(transport, device, peer, port, token) do
    with {:ok, socket} <- transport.connect(device, peer, port) do
      try do
        with :ok <-
               Wire.send(transport, socket, %{
                 "version" => 1,
                 "token" => token,
                 "command" => "console"
               }) do
          console_loop(transport, socket, <<>>)
        end
      after
        transport.close(socket)
      end
    end
  end

  defp console_loop(transport, socket, buffer) do
    case Wire.recv(transport, socket, buffer) do
      {:ok, %{"type" => "console", "message" => message}, rest} ->
        IO.puts(message)
        console_loop(transport, socket, rest)

      {:ok, %{"type" => "output", "data" => data}, rest} ->
        IO.write(data)
        console_loop(transport, socket, rest)

      {:ok, %{"type" => "input", "prompt" => prompt}, rest} ->
        case IO.gets(prompt) do
          line when is_binary(line) ->
            if String.trim(line) == ".quit" do
              Wire.send(transport, socket, %{"type" => "detach"})
            else
              with :ok <- Wire.send(transport, socket, %{"type" => "line", "data" => line}) do
                console_loop(transport, socket, rest)
              end
            end

          _ ->
            Wire.send(transport, socket, %{"type" => "detach"})
        end

      {:ok, %{"type" => "error", "message" => message}, _} ->
        {:error, message}

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :unexpected_response}
    end
  end
end
