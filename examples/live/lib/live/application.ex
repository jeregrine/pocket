defmodule Live.Application do
  use Application

  @impl true
  def start(_type, _args) do
    if marker = System.get_env("LIVE_STARTUP_MARKER"), do: File.write!(marker, "started")
    Supervisor.start_link([Live.Counter], strategy: :one_for_one, name: Live.Supervisor)
  end

  @impl true
  def stop(_state) do
    if marker = System.get_env("LIVE_SHUTDOWN_MARKER"), do: File.write!(marker, "stopped")
    :ok
  end
end
