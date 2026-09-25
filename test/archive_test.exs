defmodule Pocket.ArchiveTest do
  use ExUnit.Case, async: true

  test "embedded ZIP has absolute offsets and preserves its emulator and payloads" do
    emulator = "native emulator prefix"
    entries = [{"lib/example/ebin/a.beam", "payload"}, {"releases/start.boot", "boot"}]
    comment = "erlaotc 17.0.6\n--\n"
    executable = Pocket.Archive.executable(emulator, entries, comment)
    assert Pocket.Archive.emulator!(executable) == emulator
    assert String.ends_with?(executable, comment)
    assert {:ok, extracted} = :zip.extract(executable, [:memory])

    assert Enum.sort(extracted) ==
             Enum.map(Enum.sort(entries), fn {name, data} ->
               {String.to_charlist(name), data}
             end)
  end

  test "ZIP signatures inside contents or comments do not confuse directory lookup" do
    bytes = "payload PK\x05\x06 not a directory"
    exe = Pocket.Archive.executable("VM", [{"lib/file", bytes}], "erlaotc 1\nPK\x05\x06")
    assert Pocket.Archive.emulator!(exe) == "VM"
  end

  test "rejects duplicate and unsafe entries" do
    for name <- ["../escape", "/absolute", "lib/../escape", "lib//file", "lib\\file", "bad\0"] do
      assert_raise ArgumentError, ~r/unsafe archive path/, fn ->
        Pocket.Archive.executable("VM", [{name, "data"}], "erlaotc 1\n")
      end
    end

    assert_raise ArgumentError, ~r/duplicate/, fn ->
      Pocket.Archive.executable("VM", [{"file", "one"}, {"file", "two"}], "erlaotc 1\n")
    end
  end

  test "rejects unsupported or corrupt executables" do
    assert_raise ArgumentError, ~r/invalid or unsupported/, fn ->
      Pocket.Archive.emulator!("not a ZIP")
    end
  end
end
