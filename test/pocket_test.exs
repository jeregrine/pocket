defmodule PocketTest do
  use ExUnit.Case
  doctest Pocket

  test "greets the world" do
    assert Pocket.hello() == :world
  end
end
