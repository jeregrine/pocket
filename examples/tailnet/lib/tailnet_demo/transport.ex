defmodule TailnetDemo.Transport do
  @moduledoc false
  @callback listen(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  @callback accept(term()) :: {:ok, term()} | {:error, term()}
  @callback connect(term(), :inet.ip_address(), non_neg_integer()) ::
              {:ok, term()} | {:error, term()}
  @callback address(term()) :: {:inet.ip_address(), non_neg_integer()}
  @callback handoff(term(), pid()) :: :ok | {:error, term()}
  @callback send(term(), binary()) :: :ok | {:error, term()}
  @callback recv(term()) :: {:ok, binary()} | {:error, term()}
  @callback close(term()) :: term()
end

defmodule TailnetDemo.Transport.Tailnet do
  @moduledoc false
  @behaviour TailnetDemo.Transport
  def listen(device, port), do: Tailscale.Tcp.listen(device, :ip4, port)
  def accept(listener), do: Tailscale.Tcp.Listener.accept(listener)
  def connect(device, peer, port), do: Tailscale.Tcp.connect(device, peer, port)
  def address(listener), do: Tailscale.Tcp.Listener.local_addr(listener)
  def handoff(_socket, _pid), do: :ok
  def send(socket, bytes), do: Tailscale.Tcp.Stream.send_all(socket, bytes)
  def recv(socket), do: Tailscale.Tcp.Stream.recv(socket)

  # tailscale 0.6.1 exposes no close/cancel operation. Native resources are
  # released when references are dropped. See the README's lifecycle caveat.
  def close(_socket), do: :ok
end

defmodule TailnetDemo.Transport.Loopback do
  @moduledoc false
  @behaviour TailnetDemo.Transport
  def listen(_, port),
    do: :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

  def accept(listener), do: :gen_tcp.accept(listener)

  def connect(_, {127, 0, 0, 1} = peer, port),
    do: :gen_tcp.connect(peer, port, [:binary, active: false], 5_000)

  def connect(_, _, _), do: {:error, :loopback_only}

  def address(listener) do
    {:ok, address} = :inet.sockname(listener)
    address
  end

  def handoff(socket, pid), do: :gen_tcp.controlling_process(socket, pid)
  def send(socket, bytes), do: :gen_tcp.send(socket, bytes)
  def recv(socket), do: :gen_tcp.recv(socket, 0, 300_000)
  def close(socket), do: :gen_tcp.close(socket)
end
