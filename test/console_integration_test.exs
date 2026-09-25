defmodule Pocket.ConsoleIntegrationTest do
  use ExUnit.Case
  import Bitwise

  @moduletag :integration
  @moduletag timeout: 180_000

  setup_all do
    example = Path.expand("../examples/live", __DIR__)
    cache = Path.join(example, ".pocket/toolchains")

    unless File.exists?(cache) do
      File.mkdir_p!(Path.dirname(cache))
      File.ln_s!(Path.expand("../examples/hello/.pocket/toolchains", __DIR__), cache)
    end

    {log, status} =
      System.cmd("mix", ["pocket.build", "--offline"],
        cd: example,
        env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, log
    {:ok, source: Path.join(example, "dist/pocket-live")}
  end

  setup %{source: source} do
    # Keep Unix socket paths below macOS's 104-byte sockaddr limit.
    dir = Path.expand("tmp/c#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    executable = Path.join(dir, "live")
    File.cp!(source, executable)
    File.chmod!(executable, 0o755)
    socket_dir = Path.join(dir, "s")

    env = [
      {"POCKET_CONSOLE_DIR", socket_dir},
      {"PATH", "/usr/bin:/bin"},
      {"LIVE_STARTUP_MARKER", Path.join(dir, "started")},
      {"LIVE_SHUTDOWN_MARKER", Path.join(dir, "stopped")}
    ]

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, executable: executable, socket_dir: socket_dir, env: env}
  end

  test "copied executable attaches real IEx to the existing application", context do
    %{executable: executable, socket_dir: socket_dir, env: env, dir: dir} = context
    port = start_server(context)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      assert (File.stat!(socket_dir).mode &&& 0o777) == 0o700
      assert File.read!(Path.join(dir, "started")) == "started"
      File.rm!(Path.join(dir, "started"))
      {json, 0} = System.cmd(executable, ["--status"], env: env)
      status = JSON.decode!(json)
      assert status["os_pid"] == Integer.to_string(os_pid)
      assert status["node"] == "nonode@nohost"
      assert Enum.any?(status["applications"], &(&1["name"] == "live"))

      {output, 0} =
        console(context, """
        x = 41
        x + 1
        Enum.map([1, 2], fn n ->
          n * 2
        end)
        IO.puts("λ console")
        Live.Counter.add(1000)
        IO.puts("TARGET=" <> System.pid())
        IO.puts("VALUE=" <> to_string(Live.Counter.value()))
        IO.inspect(Supervisor.which_children(Live.Supervisor))
        raise "recoverable"
        :still_here
        :persistent_term.put(:previous_console, self())
        """)

      assert output =~ "Interactive Elixir"
      assert output =~ "42"
      assert output =~ "[2, 4]"
      assert output =~ "λ console"
      assert output =~ "TARGET=#{os_pid}"
      assert output =~ ~r/VALUE=1\d{3}/
      assert output =~ "Live.Counter"
      assert output =~ "recoverable"
      assert output =~ ":still_here"

      # EOF detached, the changed state persists, and new sessions can attach.
      {output, 0} =
        console(context, """
        IO.puts("PERSISTED=" <> to_string(Live.Counter.value()))
        IO.puts("PREVIOUS_ALIVE=" <> to_string(Process.alive?(:persistent_term.get(:previous_console))))
        """)

      assert output =~ ~r/PERSISTED=1\d{3}/
      assert output =~ "PREVIOUS_ALIVE=false"

      {output, 0} =
        console(context, """
        old = Process.whereis(Live.Counter)
        ref = Process.monitor(old)
        Process.exit(old, :kill)
        receive do: ({:DOWN, ^ref, :process, ^old, _} -> :ok)
        Process.sleep(50)
        IO.puts("RESTARTED=" <> to_string(is_pid(Process.whereis(Live.Counter)) and Process.whereis(Live.Counter) != old))
        IO.puts(String.duplicate("λ", 40_000))
        """)

      assert output =~ "RESTARTED=true"
      assert output =~ String.duplicate("λ", 40_000)
      {output, 0} = console(context, ~s|IO.puts("FINAL_LINE_WITHOUT_NEWLINE")|)
      assert output =~ "FINAL_LINE_WITHOUT_NEWLINE"

      {snapshot, 0} = System.cmd(executable, ["--observe"], env: env)
      assert snapshot =~ "MEMORY_BYTES\tREDUCTIONS\tMAILBOX"
      refute File.exists?(Path.join(dir, "started")), "client started application callbacks"
      refute File.exists?(Path.join(dir, "stopped")), "client ran application shutdown callbacks"

      assert {"stopping\n", 0} = System.cmd(executable, ["--stop"], env: env)
      await_exit(port)
      assert File.read!(Path.join(dir, "stopped")) == "stopped"
      refute File.exists?(socket_dir)
    after
      cleanup(port)
    end
  end

  test "missing instances and malformed commands never start the application", context do
    for args <- [["--console"], ["--status"], ["--console", "one", "two"]] do
      {_, status} = System.cmd(context.executable, args, env: context.env, stderr_to_stdout: true)
      assert status in [1, 2]
    end

    refute File.exists?(Path.join(context.dir, "started"))
    refute File.exists?(context.socket_dir)
  end

  test "idle consoles support background output, client SIGINT, and orderly shutdown", context do
    server = start_server(context)
    client = start_client(context)

    try do
      read_until(client, "iex(1)>")

      Port.command(
        client,
        "spawn(fn -> Process.sleep(100); IO.puts(\"BACKGROUND_OUTPUT\") end)\n"
      )

      read_until(client, "BACKGROUND_OUTPUT")
      {:os_pid, pid} = Port.info(client, :os_pid)
      System.cmd("kill", ["-INT", to_string(pid)])
      await_exit(client, :nonzero)

      {_, 0} = System.cmd(context.executable, ["--status"], env: context.env)
      second_client = start_client(context)

      try do
        read_until(second_client, "iex(1)>")
        {_, 0} = System.cmd(context.executable, ["--stop"], env: context.env)
        await_exit(server)
        await_exit(second_client)
        refute File.exists?(context.socket_dir)
      after
        cleanup(second_client)
      end
    after
      cleanup(client)
      cleanup(server)
    end
  end

  test "client rejects public directories and symlinks", context do
    File.mkdir!(context.socket_dir)
    File.chmod!(context.socket_dir, 0o755)

    {message, 1} =
      System.cmd(context.executable, ["--status"], env: context.env, stderr_to_stdout: true)

    assert message =~ "No private console directory"
    File.rmdir!(context.socket_dir)
    File.ln_s!(context.dir, context.socket_dir)

    {message, 1} =
      System.cmd(context.executable, ["--status"], env: context.env, stderr_to_stdout: true)

    assert message =~ "No private console directory"
    refute File.exists?(Path.join(context.dir, "started"))
  end

  test "duplicate instances and pre-existing directories are never overwritten", context do
    File.mkdir!(context.socket_dir)
    sentinel = Path.join(context.socket_dir, "keep")
    File.write!(sentinel, "untouched")
    {_, 1} = System.cmd(context.executable, ["serve"], env: context.env, stderr_to_stdout: true)
    assert File.read!(sentinel) == "untouched"
    refute File.exists?(Path.join(context.dir, "started"))
    File.rm!(sentinel)
    File.rmdir!(context.socket_dir)

    port = start_server(context)

    try do
      File.rm!(Path.join(context.dir, "started"))
      {_, 1} = System.cmd(context.executable, ["serve"], env: context.env, stderr_to_stdout: true)
      refute File.exists?(Path.join(context.dir, "started"))
      {json, 0} = System.cmd(context.executable, ["--status"], env: context.env)
      {:os_pid, pid} = Port.info(port, :os_pid)
      assert JSON.decode!(json)["os_pid"] == to_string(pid)
      System.cmd(context.executable, ["--stop"], env: context.env)
      await_exit(port)
    after
      cleanup(port)
    end
  end

  test "console support is inventoried without shipping the builder", %{source: source} do
    report = JSON.decode!(File.read!(source <> ".manifest.json"))
    apps = Enum.map(report["applications"], & &1["name"])
    assert "iex" in apps
    refute Enum.any?(~w(pocket mix hex), &(&1 in apps))
    assert Enum.any?(report["files"], &String.ends_with?(&1, "/Elixir.Pocket.Console.beam"))
  end

  test "explicit directory selects a second independent instance", context do
    other_dir = Path.join(context.dir, "other")
    other = %{context | socket_dir: other_dir, env: [{"POCKET_CONSOLE_DIR", other_dir}]}
    first = start_server(context)
    second = start_server(other)

    try do
      {:os_pid, first_pid} = Port.info(first, :os_pid)
      {:os_pid, second_pid} = Port.info(second, :os_pid)
      {first_json, 0} = System.cmd(context.executable, ["--status"], env: context.env)

      {second_json, 0} =
        System.cmd(context.executable, ["--status", other_dir], env: context.env)

      assert JSON.decode!(first_json)["os_pid"] == to_string(first_pid)
      assert JSON.decode!(second_json)["os_pid"] == to_string(second_pid)
      assert first_pid != second_pid
      System.cmd(context.executable, ["--stop", other_dir], env: context.env)
      await_exit(second)
      {_, 0} = System.cmd(context.executable, ["--status"], env: context.env)
      System.cmd(context.executable, ["--stop"], env: context.env)
      await_exit(first)
    after
      cleanup(first)
      cleanup(second)
    end
  end

  defp console(context, code) do
    System.cmd(
      "sh",
      ["-c", ~s(printf '%s' "$1" | "$2" --console), "--", code, context.executable],
      env: context.env,
      stderr_to_stdout: true
    )
  end

  defp start_server(context) do
    port = open_port(context, ["serve"])

    try do
      read_until(port, "ready ")
      port
    rescue
      error ->
        cleanup(port)
        reraise error, __STACKTRACE__
    end
  end

  defp start_client(context), do: open_port(context, ["--console"])

  defp open_port(context, args) do
    env = Enum.map(context.env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    Port.open({:spawn_executable, context.executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args,
      env: env
    ])
  end

  defp read_until(port, text, accumulated \\ "") do
    if String.contains?(accumulated, text) do
      accumulated
    else
      receive do
        {^port, {:data, data}} -> read_until(port, text, accumulated <> data)
        {^port, {:exit_status, status}} -> flunk("exit #{status}: #{accumulated}")
      after
        10_000 -> flunk("did not receive #{inspect(text)}: #{accumulated}")
      end
    end
  end

  defp await_exit(port, expected \\ 0) do
    receive do
      {^port, {:data, _}} ->
        await_exit(port, expected)

      {^port, {:exit_status, status}} ->
        if expected == :nonzero, do: assert(status != 0), else: assert(status == expected)
    after
      10_000 -> flunk("service did not stop")
    end
  end

  defp cleanup(port) do
    if info = Port.info(port) do
      System.cmd("kill", ["-KILL", to_string(info[:os_pid])], stderr_to_stdout: true)

      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
