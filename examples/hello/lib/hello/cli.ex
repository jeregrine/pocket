defmodule Hello.CLI do
  @build_environment Application.compile_env!(:hello, :build_environment)

  def main(["--version"]) do
    IO.puts("hello 0.1.0")
    :ok
  end

  def main(["--fail"]) do
    IO.puts(:stderr, "requested failure")
    {:error, 7}
  end

  def main(["--crash"]), do: raise("requested crash")

  def main(["--background"]) do
    spawn(fn -> Process.sleep(:infinity) end)
    IO.puts("background process started")
    :ok
  end

  def main(["--echo"]) do
    IO.binwrite(IO.binread(:stdio, :eof))
    :ok
  end

  def main(["--wait"]) do
    IO.puts("ready")
    Process.sleep(:infinity)
  end

  def main(["--inspect-runtime"]) do
    IO.puts(
      JSON.encode!(%{
        "mix" => Code.ensure_loaded?(Mix),
        "hex" => Code.ensure_loaded?(Hex),
        "node" => to_string(node()),
        "schedulers" => :erlang.system_info(:schedulers_online),
        "otp" => to_string(:erlang.system_info(:otp_release)),
        "application_started" => is_pid(Process.whereis(Hello.Supervisor)),
        "compiled_environment" => @build_environment,
        "runtime_environment" => Application.fetch_env!(:hello, :build_environment)
      })
    )

    :ok
  end

  def main(args) do
    IO.puts("Hello, #{Enum.join(args, " ") |> then(&if(&1 == "", do: "world", else: &1))}!")
    :ok
  end
end
