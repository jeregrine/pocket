defmodule Pocket.ConsoleTest do
  use ExUnit.Case

  test "default address is per user and per configured executable, with an explicit override" do
    previous = System.get_env("POCKET_CONSOLE_DIR")
    previous_name = Application.get_env(:pocket_runtime, :name)

    on_exit(fn ->
      if previous,
        do: System.put_env("POCKET_CONSOLE_DIR", previous),
        else: System.delete_env("POCKET_CONSOLE_DIR")

      if previous_name,
        do: Application.put_env(:pocket_runtime, :name, previous_name),
        else: Application.delete_env(:pocket_runtime, :name)
    end)

    System.delete_env("POCKET_CONSOLE_DIR")
    Application.put_env(:pocket_runtime, :name, "first")
    cache = to_string(:filename.basedir(:user_cache, ~c"pocket"))
    assert Pocket.Console.directory() == Path.join(cache, "first")
    Application.put_env(:pocket_runtime, :name, "second")
    assert Pocket.Console.directory() == Path.join(cache, "second")
    System.put_env("POCKET_CONSOLE_DIR", "/explicit/instance")
    assert Pocket.Console.directory() == "/explicit/instance"
  end

  test "normal CLI arguments are not management commands" do
    assert Pocket.Console.command(["serve"]) == :not_console
    assert Pocket.Console.command([]) == :not_console
    assert Pocket.Console.command(["something", "--console"]) == :not_console
  end
end
