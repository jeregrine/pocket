defmodule Pocket.TailnetNativeIntegrationTest do
  use ExUnit.Case

  @moduletag :native
  @moduletag timeout: 600_000

  @tag :tmp_dir
  test "one copied executable loads its static NIF and acts as server and client", %{tmp_dir: dir} do
    sdk = System.fetch_env!("POCKET_TEST_NATIVE_SDK") |> Path.expand()
    example = Path.expand("../examples/tailnet", __DIR__)

    {log, status} =
      System.cmd("mix", ["pocket.build", "--offline", "--native-sdk", sdk],
        cd: example,
        env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, log
    source = Path.join(example, "dist/tailnet-demo")
    report = JSON.decode!(File.read!(source <> ".manifest.json"))

    assert [%{"module" => "Elixir.Tailscale.Native", "init" => "ts_elixir_nif_init"}] =
             report["native"]

    refute Enum.any?(report["files"], &(Path.extname(&1) in ~w(.so .dylib .dll .a .o)))
    refute Enum.any?(report["applications"], &(&1["name"] in ~w(mix hex pocket)))
    # Embedded console mode ships the session, not an automatic local listener.
    refute Enum.any?(
             report["files"],
             &String.ends_with?(&1, "/Elixir.Pocket.Console.Server.beam")
           )

    assert Enum.any?(
             report["files"],
             &String.ends_with?(&1, "/Elixir.Pocket.Console.Session.beam")
           )

    executable = Path.join(dir, "tailnet-demo")
    File.cp!(source, executable)
    File.chmod!(executable, 0o755)
    File.mkdir!(Path.join(dir, "tmp"))
    token = Base.encode64(:crypto.strong_rand_bytes(32))

    env =
      Pocket.Toolchain.clean_env() ++
        [
          {"PATH", "/usr/bin:/bin"},
          {"HOME", dir},
          {"TMPDIR", Path.join(dir, "tmp")},
          {"XDG_DATA_HOME", dir},
          {"POCKET_CONSOLE_DIR", Path.join(dir, "must-not-exist")},
          {"POCKET_DEMO_TOKEN", token},
          {"TS_AUTHKEY", nil},
          {"RUST_LOG", "off"},
          {"DYLD_LIBRARY_PATH", nil},
          {"LD_LIBRARY_PATH", nil}
        ]

    command = fn args ->
      System.cmd(executable, args, cd: dir, env: env, stderr_to_stdout: true)
    end

    assert {"Static Tailscale NIF loaded\n", 0} = command.(["--smoke"])

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: String.to_charlist(dir),
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
          end),
        args:
          Enum.map(["serve", "--local", "--allow-console", "--port", "0"], &String.to_charlist/1)
      ])

    {:os_pid, server_pid} = Port.info(port, :os_pid)

    try do
      number = await_listener(port, "")
      endpoint = ["--local", "--port", number]
      {output, 0} = command.(["status" | endpoint])
      assert JSON.decode!(output)["value"] == 0
      {output, 0} = command.(["add", "7" | endpoint])
      assert JSON.decode!(output)["value"] == 7

      script = ~S"""
      printf '%s\n' 'TailnetDemo.Counter.add(5)' 'IO.puts("SERVER=" <> System.pid())' '.quit' |
        "$1" console --local --port "$2"
      """

      {output, 0} =
        System.cmd("/bin/sh", ["-c", script, "--", executable, number],
          cd: dir,
          env: env,
          stderr_to_stdout: true
        )

      assert output =~ "Remote IEx"
      assert output =~ "SERVER=#{server_pid}"
      {output, 0} = command.(["status" | endpoint])
      assert JSON.decode!(output)["value"] == 12
      refute File.exists?(Path.join(dir, "must-not-exist"))
    after
      if Port.info(port) do
        System.cmd("/bin/kill", ["-TERM", Integer.to_string(server_pid)], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          5_000 ->
            System.cmd("/bin/kill", ["-KILL", Integer.to_string(server_pid)],
              stderr_to_stdout: true
            )
        end

        if Port.info(port), do: Port.close(port)
      end
    end

    assert Enum.sort(File.ls!(dir)) == ["tailnet-demo", "tmp"]
    assert File.ls!(Path.join(dir, "tmp")) == []
  end

  defp await_listener(port, buffer) do
    case Regex.run(~r/Listening on 127\.0\.0\.1:(\d+);/, buffer) do
      [_, number] ->
        number

      nil ->
        receive do
          {^port, {:data, data}} -> await_listener(port, buffer <> data)
          {^port, {:exit_status, status}} -> flunk("server exited #{status}: #{buffer}")
        after
          10_000 -> flunk("server did not become ready: #{buffer}")
        end
    end
  end
end
