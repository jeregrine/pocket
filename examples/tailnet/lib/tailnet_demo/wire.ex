defmodule TailnetDemo.Wire do
  @moduledoc false
  @limit 65_536
  def limit, do: @limit

  def send(transport, socket, message) do
    bytes = JSON.encode!(message)

    if byte_size(bytes) > @limit do
      {:error, :frame_too_large}
    else
      transport.send(socket, <<byte_size(bytes)::32, bytes::binary>>)
    end
  end

  def recv(transport, socket, buffer \\ <<>>) do
    case decode(buffer) do
      :more ->
        case transport.recv(socket) do
          {:ok, <<>>} -> {:error, :closed}
          {:ok, bytes} -> recv(transport, socket, buffer <> bytes)
          error -> error
        end

      result ->
        result
    end
  end

  def decode(<<length::32, _::binary>>) when length > @limit, do: {:error, :frame_too_large}

  def decode(<<length::32, bytes::binary-size(length), rest::binary>>) do
    case JSON.decode(bytes) do
      {:ok, message} when is_map(message) -> {:ok, message, rest}
      _ -> {:error, :invalid_message}
    end
  end

  def decode(_), do: :more
end
