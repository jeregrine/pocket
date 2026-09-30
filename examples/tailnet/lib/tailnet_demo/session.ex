defmodule TailnetDemo.Session do
  @moduledoc false
  use GenServer, restart: :temporary
  alias TailnetDemo.{Counter, Wire}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       transport: Keyword.fetch!(opts, :transport),
       socket: nil,
       token_hash: Keyword.fetch!(opts, :token_hash),
       allow_console: Keyword.get(opts, :allow_console, false),
       mode: :auth,
       reader: nil,
       evaluator: nil,
       pending: nil,
       timer: Process.send_after(self(), :expired, 5_000)
     }}
  end

  @impl true
  def handle_info({:socket, socket}, state) do
    session = self()

    reader =
      spawn_link(fn -> authenticate(session, state.transport, socket, state.token_hash) end)

    {:noreply, %{state | socket: socket, reader: reader}}
  end

  def handle_info({:authenticated, %{"command" => command} = request}, %{mode: :auth} = state) do
    Process.cancel_timer(state.timer)
    state = %{state | timer: Process.send_after(self(), :expired, 300_000), token_hash: nil}
    dispatch(command, request, state)
  end

  def handle_info(:unauthorized, state) do
    reply(state, %{"type" => "error", "message" => "unauthorized"})
    {:stop, :normal, state}
  end

  def handle_info(
        {:frame, %{"type" => "line", "data" => line}},
        %{mode: :console, pending: pending} = state
      )
      when is_binary(line) and not is_nil(pending) do
    {from, ref} = pending
    send(from, {:pocket_console_input, ref, line})
    send(state.reader, :next_frame)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:frame, %{"type" => "detach"}}, %{mode: :console} = state),
    do: {:stop, :normal, state}

  def handle_info({:frame, _}, state), do: {:stop, :normal, state}
  def handle_info({:wire_error, _}, state), do: {:stop, :normal, state}
  def handle_info(:expired, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _}, state) when pid == state.reader or pid == state.evaluator,
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call({:console_output, bytes}, _, %{mode: :console} = state) do
    result = reply(state, %{"type" => "output", "data" => bytes})
    {:reply, result, state}
  end

  def handle_call({:console_input, from, channel}, _, %{mode: :console, pending: nil} = state) do
    result = reply(state, %{"type" => "input", "prompt" => ""})
    {:reply, result, %{state | pending: {from, channel}}}
  end

  def handle_call({:console_input, _, _}, _, state),
    do: {:reply, {:error, :input_pending}, state}

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    if is_pid(state.reader), do: Process.exit(state.reader, :kill)
    if is_pid(state.evaluator), do: Process.exit(state.evaluator, :shutdown)
    if state.socket, do: state.transport.close(state.socket)
  end

  defp dispatch("status", _, state), do: result(Counter.status(), state)

  defp dispatch("add", %{"amount" => amount}, state)
       when is_integer(amount) and amount in -1_000_000..1_000_000,
       do: result(Counter.add(amount), state)

  defp dispatch("console", _, %{allow_console: true} = state) do
    parent = self()
    send(state.reader, :next_frame)

    evaluator =
      spawn_link(fn ->
        channel = make_ref()

        Pocket.Console.Session.run(
          channel,
          fn bytes -> GenServer.call(parent, {:console_output, bytes}) end,
          fn -> GenServer.call(parent, {:console_input, self(), channel}) end
        )
      end)

    reply(state, %{
      "type" => "console",
      "message" => "Remote IEx. Type .quit or send EOF to detach."
    })

    {:noreply, %{state | mode: :console, evaluator: evaluator}}
  end

  defp dispatch("console", _, state) do
    reply(state, %{"type" => "error", "message" => "console is disabled"})
    {:stop, :normal, state}
  end

  defp dispatch(_, _, state) do
    reply(state, %{"type" => "error", "message" => "unsupported command"})
    {:stop, :normal, state}
  end

  defp result(value, state) do
    reply(state, %{"type" => "result", "value" => value})
    {:stop, :normal, state}
  end

  defp reply(state, message), do: Wire.send(state.transport, state.socket, message)

  defp authenticate(session, transport, socket, expected_hash) do
    with {:ok, %{"version" => 1, "token" => token, "command" => command} = frame, rest}
         when is_binary(token) and is_binary(command) <- Wire.recv(transport, socket),
         true <- :crypto.hash_equals(:crypto.hash(:sha256, token), expected_hash) do
      # A GenServer's last message can be logged on failure. Remove credentials
      # before handing the authenticated command to the session process.
      send(session, {:authenticated, Map.delete(frame, "token")})

      receive do
        :next_frame -> read_loop(session, transport, socket, rest)
      end
    else
      {:error, reason} -> send(session, {:wire_error, reason})
      _ -> send(session, :unauthorized)
    end
  end

  defp read_loop(session, transport, socket, buffer) do
    case Wire.recv(transport, socket, buffer) do
      {:ok, frame, rest} ->
        send(session, {:frame, frame})
        # Do not let a fast sender grow the session's mailbox without bound.
        receive do
          :next_frame -> read_loop(session, transport, socket, rest)
        end

      {:error, reason} ->
        send(session, {:wire_error, reason})
    end
  end
end
