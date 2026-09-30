defmodule TailnetDemo.Server do
  @moduledoc """
  A small supervised control endpoint. Starting a client does not start this tree.
  """
  use Supervisor

  def start_link(opts) do
    {token, opts} = Keyword.pop!(opts, :token)
    # Child specs can appear in supervision crash reports. Never retain the
    # plaintext operator token there.
    opts = Keyword.put(opts, :token_hash, :crypto.hash(:sha256, token))
    Supervisor.start_link(__MODULE__, opts)
  end

  def address(server) do
    {_, listener, _, _} =
      Enum.find(Supervisor.which_children(server), &(elem(&1, 0) == TailnetDemo.Listener))

    GenServer.call(listener, :address)
  end

  @impl true
  def init(opts) do
    # Keep the session cap below the default dirty-I/O scheduler count: the
    # current native accept/recv operations are blocking dirty-I/O NIFs.
    sessions = [name: TailnetDemo.Sessions, strategy: :one_for_one, max_children: 2]

    Supervisor.init(
      [
        TailnetDemo.Counter,
        {DynamicSupervisor, sessions},
        {TailnetDemo.Listener, opts}
      ],
      strategy: :one_for_one
    )
  end
end

defmodule TailnetDemo.Listener do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    {:ok, listener} = transport.listen(opts[:device], Keyword.get(opts, :port, 4141))
    acceptor = spawn_link(fn -> accept(transport, listener, opts) end)
    {:ok, %{transport: transport, listener: listener, acceptor: acceptor}}
  end

  @impl true
  def handle_call(:address, _, state),
    do: {:reply, state.transport.address(state.listener), state}

  @impl true
  def terminate(_, state) do
    state.transport.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
  end

  defp accept(transport, listener, opts) do
    case transport.accept(listener) do
      {:ok, socket} ->
        case DynamicSupervisor.start_child(TailnetDemo.Sessions, {TailnetDemo.Session, opts}) do
          {:ok, pid} ->
            case transport.handoff(socket, pid) do
              :ok ->
                send(pid, {:socket, socket})

              _ ->
                transport.close(socket)
                Process.exit(pid, :shutdown)
            end

          _ ->
            transport.close(socket)
        end

        accept(transport, listener, opts)

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end
end
