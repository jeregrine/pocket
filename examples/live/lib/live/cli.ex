defmodule Live.CLI do
  def main(["serve"]) do
    IO.puts("ready #{System.pid()}")
    Process.sleep(:infinity)
  end

  def main(_) do
    IO.puts(:stderr, "usage: pocket-live serve")
    {:error, 2}
  end
end
