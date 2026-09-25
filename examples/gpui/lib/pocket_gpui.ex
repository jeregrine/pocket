defmodule PocketGPUI.View do
  use GPUI.View

  @impl true
  def render(assigns) do
    ~GPUI"""
    <div class="flex flex-col items-center justify-center w-full h-full gap-4 bg-slate-950">
      <text class="text-3xl text-white">Pocket + GPUI</text>
      <text class="text-xl text-white">Count: {assigns.count}</text>
      <div id="increment" phx-click="increment" class="p-4 bg-blue-600 rounded-lg cursor-pointer">
        <text class="text-white">Increment</text>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("increment", _event, assigns) do
    {:noreply, %{assigns | count: assigns.count + 1}}
  end
end

defmodule PocketGPUI.Desktop do
  use GPUI.Application

  @impl true
  def mount(_args) do
    {:ok,
     [
       window "Pocket + GPUI" do
         size(480, 320)
         root(PocketGPUI.View, count: 0)
       end
     ]}
  end
end

defmodule PocketGPUI do
  def main(args) do
    {:ok, runtime} = GPUI.Runtime.start_link(app: PocketGPUI.Desktop)
    :ok = GPUI.Runtime.subscribe(runtime)

    try do
      if "--smoke" in args do
        :ok = GPUI.Runtime.await_frame(runtime, 1)
        {:ok, %{windows: []}} = GPUI.Runtime.close_window(runtime, 1)
        IO.puts("GPUI native frame rendered; window closed")
        :ok
      else
        wait_for_close(runtime)
      end
    after
      if Process.alive?(runtime), do: GenServer.stop(runtime)
    end
  end

  defp wait_for_close(runtime) do
    if GPUI.Runtime.windows(runtime) == [] do
      :ok
    else
      receive do
        {:gpui, ^runtime, _update} -> wait_for_close(runtime)
      end
    end
  end
end
