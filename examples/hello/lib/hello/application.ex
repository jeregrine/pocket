defmodule Hello.Application do
  use Application

  @impl true
  def start(_type, _args) do
    if marker = System.get_env("HELLO_STARTUP_MARKER"), do: File.write!(marker, "started")
    Supervisor.start_link([], strategy: :one_for_one, name: Hello.Supervisor)
  end

  @impl true
  def stop(_state) do
    if System.get_env("HELLO_STALL_ON_STOP") == "1", do: Process.sleep(:infinity)
    if marker = System.get_env("HELLO_SHUTDOWN_MARKER"), do: File.write!(marker, "stopped")
    :ok
  end
end
