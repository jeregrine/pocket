defmodule TailnetDemo.Counter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)

  def add(amount) when is_integer(amount) and amount in -1_000_000..1_000_000,
    do: GenServer.call(__MODULE__, {:add, amount})

  @impl true
  def init(_) do
    {:ok, %{value: 0, started: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, snapshot(state), state}

  def handle_call({:add, amount}, _, state) do
    state = %{state | value: state.value + amount}
    {:reply, snapshot(state), state}
  end

  defp snapshot(state) do
    %{"value" => state.value, "uptime_ms" => System.monotonic_time(:millisecond) - state.started}
  end
end
