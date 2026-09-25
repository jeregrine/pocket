defmodule Pocket.NativeTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "SDK validation fails closed on corrupt, missing, unsafe, and incompatible inputs",
       %{tmp_dir: dir} do
    files = %{"link.exs" => "# linker", "driver_tab.i" => "registry", "beam.o" => "object"}
    Enum.each(files, fn {path, bytes} -> File.write!(Path.join(dir, path), bytes) end)

    manifest = %{
      "schema" => 1,
      "erts" => to_string(:erlang.system_info(:version)),
      "target" => to_string(:erlang.system_info(:system_architecture)),
      "link_args" => ["$SDK/beam.o"],
      "files" =>
        Map.new(files, fn {path, _} -> {path, Pocket.Toolchain.digest(Path.join(dir, path))} end)
    }

    write = fn data -> File.write!(Path.join(dir, "sdk.json"), JSON.encode!(data)) end
    write.(manifest)
    assert Pocket.Compiler.verify_sdk!(dir) == manifest

    write.(Map.put(manifest, "erts", "0.0"))
    assert_raise Mix.Error, ~r/ERTS/, fn -> Pocket.Compiler.verify_sdk!(dir) end

    write.(Map.put(manifest, "target", "not-this-cpu-unknown-linux-gnu"))
    assert_raise Mix.Error, ~r/target/, fn -> Pocket.Compiler.verify_sdk!(dir) end

    write.(put_in(manifest, ["files"], Map.delete(manifest["files"], "beam.o")))
    assert_raise Mix.Error, ~r/does not inventory/, fn -> Pocket.Compiler.verify_sdk!(dir) end

    write.(put_in(manifest, ["files", "../outside"], "irrelevant"))
    assert_raise Mix.Error, ~r/Unsafe/, fn -> Pocket.Compiler.verify_sdk!(dir) end

    write.(manifest)
    File.write!(Path.join(dir, "beam.o"), "corrupt")
    assert_raise Mix.Error, ~r/digest mismatch/, fn -> Pocket.Compiler.verify_sdk!(dir) end
  end

  test "only the registered GPUI library is replaced by the static adapter" do
    native = [%{"module" => "Elixir.GPUI.Native.NIF"}]
    assert Pocket.Native.linked_file?(:gpui_native, "native/gpui_nif.so", native)
    assert Pocket.Native.linked_file?(:gpui_native, "native/gpui_nif_vanilla.so", native)
    refute Pocket.Native.linked_file?(:gpui_native, "native/gpui_nif.so", [])
    refute Pocket.Native.linked_file?(:other, "native/gpui_nif.so", native)
    refute Pocket.Native.linked_file?(:gpui_native, "native/unrelated.so", native)
    refute Pocket.Native.linked_file?(:gpui_native, "images/logo.png", native)
  end

  test "unsupported GPUI versions fail rather than using an incompatible adapter" do
    assert_raise Mix.Error, ~r/supports gpui_native 0.2.0/, fn ->
      Pocket.Native.build!(%{gpui_native: %{version: "9.0.0"}}, nil, nil)
    end
  end
end
