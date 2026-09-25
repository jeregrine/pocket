defmodule Live.Counter do
  @moduledoc "A supervised, ticking worker you can inspect and change from IEx."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def value, do: GenServer.call(__MODULE__, :value)
  def add(amount) when is_integer(amount), do: GenServer.call(__MODULE__, {:add, amount})

  @impl true
  def init(value) do
    schedule_tick()
    {:ok, value}
  end

  @impl true
  def handle_call(:value, _from, value), do: {:reply, value, value}

  def handle_call({:add, amount}, _from, value),
    do: {:reply, value + amount, value + amount}

  @impl true
  def handle_info(:tick, value) do
    schedule_tick()
    {:noreply, value + 1}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)
end
