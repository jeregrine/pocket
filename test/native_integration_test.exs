defmodule Pocket.NativeIntegrationTest do
  use ExUnit.Case

  @moduletag :native
  @moduletag timeout: 600_000

  @tag :tmp_dir
  test "GPUI renders from a copied executable without a shared NIF", %{tmp_dir: dir} do
    sdk = System.fetch_env!("POCKET_TEST_NATIVE_SDK") |> Path.expand()
    example = Path.expand("../examples/gpui", __DIR__)

    {log, status} =
      System.cmd("mix", ["pocket.build", "--offline", "--native-sdk", sdk],
        cd: example,
        env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, log

    source = Path.join(example, "dist/pocket_gpui")
    report = JSON.decode!(File.read!(source <> ".manifest.json"))
    assert [%{"module" => "Elixir.GPUI.Native.NIF"}] = report["native"]
    refute Enum.any?(report["files"], &(Path.extname(&1) in ~w(.so .dylib .dll .a .o)))
    refute Enum.any?(report["applications"], &(&1["name"] in ~w(mix hex pocket)))

    executable = Path.join(dir, "counter")
    File.cp!(source, executable)
    File.chmod!(executable, 0o755)
    File.mkdir!(Path.join(dir, "tmp"))

    # Keep the desktop session's display variables, but remove build tools,
    # project paths, home caches, and VM flags from the test's environment.
    {log, status} =
      System.cmd(executable, ["--smoke"],
        cd: dir,
        env:
          Pocket.Toolchain.clean_env() ++
            [
              {"PATH", "/usr/bin:/bin"},
              {"HOME", dir},
              {"TMPDIR", Path.join(dir, "tmp")},
              {"DYLD_LIBRARY_PATH", nil},
              {"LD_LIBRARY_PATH", nil}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, log
    assert log =~ "GPUI native frame rendered; window closed"

    # OS graphics frameworks may create caches; no application payload is
    # extracted. The archive's only deployable file was the copied executable.
    extracted = Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
    refute Enum.any?(extracted, &(Path.extname(&1) in ~w(.beam .so .dylib .a)))
  end
end
