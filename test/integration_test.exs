defmodule Pocket.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration
  @moduletag timeout: 180_000

  setup_all do
    example = Path.expand("../examples/hello", __DIR__)
    marker = Path.join(example, "_build/build-must-not-start-application")
    File.rm(marker)

    {log, status} =
      System.cmd("mix", ["pocket.build", "--offline"],
        cd: example,
        env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}, {"HELLO_STARTUP_MARKER", marker}],
        stderr_to_stdout: true
      )

    assert status == 0, log
    refute File.exists?(marker), "Application callbacks must not execute during AOT recording"
    {:ok, example: example, executable: Path.join(example, "dist/hello")}
  end

  @tag :tmp_dir
  test "only the copied executable is needed; no runtime extraction", %{
    executable: source,
    tmp_dir: dir
  } do
    executable = Path.join(dir, "hello")
    File.cp!(source, executable)
    File.chmod!(executable, 0o755)
    scratch = Path.join(dir, "runtime-tmp")
    File.mkdir!(scratch)

    env = System.find_executable("env")

    run = fn args ->
      System.cmd(
        env,
        [
          "-i",
          "PATH=/usr/bin:/bin",
          "HOME=#{dir}",
          "TMPDIR=#{scratch}",
          "ERL_FLAGS=-eval erlang:halt(99).",
          "ERL_LIBS=/untrusted",
          executable | args
        ],
        cd: dir,
        stderr_to_stdout: true
      )
    end

    assert run.(["--version"]) == {"hello 0.1.0\n", 0}
    assert run.(["world", "with spaces", "λ"]) == {"Hello, world with spaces λ!\n", 0}
    assert run.(["-eval", "halt()."]) == {"Hello, -eval halt().!\n", 0}
    assert run.(["--fail"]) == {"requested failure\n", 7}
    {crash, 1} = run.(["--crash"])
    assert crash =~ "requested crash"
    {runtime, 0} = run.(["--inspect-runtime"])

    assert %{
             "mix" => false,
             "hex" => false,
             "node" => "nonode@nohost",
             "schedulers" => 1,
             "application_started" => true,
             "compiled_environment" => "prod",
             "runtime_environment" => "prod"
           } =
             JSON.decode!(runtime)

    assert File.ls!(scratch) == []
    assert Enum.sort(File.ls!(dir)) == ["hello", "runtime-tmp"]
  end

  @tag :tmp_dir
  test "application cleanup runs and background processes do not keep the CLI alive",
       %{executable: executable, tmp_dir: dir} do
    marker = Path.join(dir, "shutdown")

    assert {"background process started\n", 0} =
             System.cmd(executable, ["--background"], env: [{"HELLO_SHUTDOWN_MARKER", marker}])

    assert File.read!(marker) == "stopped"
  end

  test "a blocked application stop is bounded by the configured shutdown deadline",
       %{executable: executable} do
    {micros, {output, status}} =
      :timer.tc(fn ->
        System.cmd(executable, ["--version"],
          env: [{"HELLO_STALL_ON_STOP", "1"}],
          stderr_to_stdout: true
        )
      end)

    assert status == 0
    assert output =~ "hello 0.1.0"
    assert output =~ "shutdown_timeout"
    assert micros < 5_000_000
  end

  test "stdin remains usable in pipes", %{executable: executable} do
    assert {"hello from stdin\n", 0} =
             System.cmd("sh", [
               "-c",
               ~s(printf 'hello from stdin\\n' | "$1" --echo),
               "--",
               executable
             ])
  end

  test "SIGINT terminates without the Erlang BREAK menu", %{executable: executable} do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--wait"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      assert_receive {^port, {:data, "ready\n"}}, 5_000
      {_, 0} = System.cmd("kill", ["-INT", Integer.to_string(pid)])
      assert_receive {^port, {:exit_status, status}}, 5_000
      assert status != 0
    after
      if Port.info(port) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        Port.close(port)
      end
    end
  end

  test "manifest inventories the executable and excludes build tools", %{executable: executable} do
    report = JSON.decode!(File.read!(executable <> ".manifest.json"))
    assert report["executable_sha256"] == Pocket.Toolchain.digest(executable)
    apps = Enum.map(report["applications"], & &1["name"])
    assert "hello" in apps
    assert "pocket_runtime" in apps
    refute Enum.any?(~w(pocket mix hex iex megaco), &(&1 in apps))
    assert Enum.any?(report["files"], &String.ends_with?(&1, "/jitc/atoms"))
  end

  @tag :tmp_dir
  test "unsupported native assets and missing entry points preserve the previous executable",
       %{example: example, tmp_dir: dir} do
    fixture!(dir, example, Failure.CLI)
    source = Path.join(dir, "lib/cli.ex")
    File.write!(source, "defmodule Failure.CLI do\n  def main(_), do: :ok\nend\n")
    File.mkdir_p!(Path.join(dir, "priv"))
    File.write!(Path.join(dir, "priv/custom.so"), "unsupported native payload")
    File.mkdir_p!(Path.join(dir, "dist"))
    output = Path.join(dir, "dist/failure")
    File.write!(output, "previous executable")
    {log, 1} = build_fixture(dir)
    assert log =~ "priv/ assets or native libraries"
    assert File.read!(output) == "previous executable"
    File.rm!(Path.join(dir, "priv/custom.so"))
    File.write!(source, "defmodule Failure.CLI do\nend\n")
    {log, 1} = build_fixture(dir)
    assert log =~ "must export main/1"
    assert File.read!(output) == "previous executable"
    assert Path.wildcard(Path.join(dir, "_build/pocket/**/assemble-*")) == []
  end

  @tag :tmp_dir
  test "MFA entry points receive CLI argv before their configured arguments",
       %{example: example, tmp_dir: dir} do
    fixture!(dir, example, {Failure.CLI, :run, ["prefix", [separator: "|"]]})

    File.write!(Path.join(dir, "lib/cli.ex"), """
    defmodule Failure.CLI do
      def run(argv, prefix, options) do
        ^argv = System.argv()
        IO.puts(prefix <> ": " <> Enum.join(argv, options[:separator]))
        :ok
      end

      def start(argv) do
        ^argv = System.argv()
        IO.puts(Enum.join(argv, "|"))
        {:error, 7}
      end
    end
    """)

    {log, status} = build_fixture(dir)
    assert status == 0, log
    executable = Path.join(dir, "dist/failure")
    assert System.cmd(executable, ["one", "two"]) == {"prefix: one|two\n", 0}
    assert System.cmd(executable, []) == {"prefix: \n", 0}

    write_project!(dir, {Failure.CLI, :start, []})
    {log, status} = build_fixture(dir)
    assert status == 0, log
    assert System.cmd(executable, ["three"]) == {"three\n", 7}

    write_project!(dir, {Failure.CLI, :run, ["missing second argument"]})
    {log, 1} = build_fixture(dir)
    assert log =~ "must export run/2"
    assert System.cmd(executable, ["still works"]) == {"still works\n", 7}
  end

  defp fixture!(dir, example, main) do
    write_project!(dir, main)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.cp!(Path.join(example, "pocket.lock"), Path.join(dir, "pocket.lock"))
    # Reuse only the verified toolchain cache, not any compiled project state.
    File.mkdir_p!(Path.join(dir, ".pocket"))
    File.ln_s!(Path.join(example, ".pocket/toolchains"), Path.join(dir, ".pocket/toolchains"))
  end

  defp write_project!(dir, main) do
    root = Path.expand("..", __DIR__)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Failure.MixProject do
      use Mix.Project
      def project do
        [app: :failure, version: "0.1.0",
         pocket: [main: #{inspect(main)}],
         deps: [{:pocket, path: #{inspect(root)}, runtime: false}]]
      end
      def application, do: [extra_applications: [:logger]]
    end
    """)
  end

  defp build_fixture(dir) do
    System.cmd("mix", ["pocket.build", "--offline"],
      cd: dir,
      env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}],
      stderr_to_stdout: true
    )
  end
end
