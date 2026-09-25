defmodule Pocket.Runtime do
  @moduledoc false

  # This module alone, not the Pocket build application, is shipped to clients.
  def main do
    :io.setopts(:standard_io, encoding: :unicode)
    :io.setopts(:standard_error, encoding: :unicode)
    argv = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    System.argv(argv)
    main = Application.fetch_env!(:pocket_runtime, :main)

    status =
      try do
        case invoke(main, argv) do
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

  defp invoke(module, argv) when is_atom(module), do: module.main(argv)
  defp invoke({module, function, args}, argv), do: apply(module, function, [argv | args])
end
