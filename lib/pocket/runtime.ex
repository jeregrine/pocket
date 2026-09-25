defmodule Pocket.Runtime do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Pocket.Runtime.Supervisor)
  end

  # The builder ships this runtime, never the Pocket build application.
  def main do
    :io.setopts(:standard_io, encoding: :unicode)
    :io.setopts(:standard_error, encoding: :unicode)
    argv = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    System.argv(argv)
    main = Application.fetch_env!(:pocket_runtime, :main)

    status =
      try do
        case dispatch(main, argv) do
          :ok -> 0
          {:error, status} when is_integer(status) and status in 1..255 -> status
          other -> raise "entry point must return :ok or {:error, 1..255}, got: #{inspect(other)}"
        end
      catch
        kind, reason ->
          IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
          1
      end

    # This includes Logger's shutdown, within the launcher's -shutdown_time
    # deadline. An unbounded Logger.flush before init:stop could hang forever.
    :init.stop(status)
  end

  defp dispatch(main, argv) do
    if Application.get_env(:pocket_runtime, :console, false) do
      case Pocket.Console.command(argv) do
        :not_console ->
          app = Application.fetch_env!(:pocket_runtime, :app)

          {:ok, _} =
            Supervisor.start_child(
              Pocket.Runtime.Supervisor,
              {Pocket.Console, directory: Pocket.Console.directory()}
            )

          {:ok, _} = Application.ensure_all_started(app, :permanent)
          invoke(main, argv)

        result ->
          result
      end
    else
      invoke(main, argv)
    end
  end

  defp invoke(module, argv) when is_atom(module), do: module.main(argv)
  defp invoke({module, function, args}, argv), do: apply(module, function, [argv | args])
end
