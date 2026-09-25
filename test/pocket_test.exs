defmodule PocketTest do
  use ExUnit.Case, async: true

  test "toolchain covers the four native targets with pinned HTTPS artifacts" do
    manifest = Pocket.Toolchain.manifest()
    assert manifest["schema"] == 1

    assert Map.keys(manifest["artifacts"]) |> Enum.sort() ==
             ~w(darwin-arm64 darwin-x86_64 linux-arm64 linux-x86_64)

    for {_target, artifact} <- manifest["artifacts"] do
      assert artifact["sha256"] =~ ~r/\A[0-9a-f]{64}\z/

      assert URI.parse(artifact["url"]).scheme == "https"
      refute String.contains?(artifact["url"], ["/main/", "/latest/"])
    end
  end

  @tag :tmp_dir
  test "lock uses JSON, round trips, and refuses modified manifests", %{tmp_dir: dir} do
    path = Path.join(dir, "pocket.lock")
    expected = Pocket.Toolchain.manifest()
    assert Pocket.Toolchain.lock!(path) == expected
    assert JSON.decode!(File.read!(path)) == expected
    assert Pocket.Toolchain.lock!(path) == expected
    File.write!(path, JSON.encode!(Map.put(expected, "id", "attacker")))
    assert_raise Mix.Error, ~r/does not match/, fn -> Pocket.Toolchain.lock!(path) end
  end

  @tag :tmp_dir
  test "verification fails closed on changed bytes", %{tmp_dir: dir} do
    path = Path.join(dir, "toolchain")
    File.write!(path, "trusted")
    digest = Pocket.Toolchain.digest(path)
    assert :ok == Pocket.Toolchain.verify!(path, digest)
    File.write!(path, "modified")

    assert_raise Mix.Error, ~r/refusing to execute/, fn ->
      Pocket.Toolchain.verify!(path, digest)
    end
  end

  test "application closure is minimal and missing required apps fail" do
    apps = Pocket.Builder.resolve!([:logger])
    assert Map.has_key?(apps, :logger)
    assert Map.has_key?(apps, :kernel)
    refute Map.has_key?(apps, :mix)
    refute Map.has_key?(apps, :megaco)

    assert_raise Mix.Error, ~r/Missing runtime application/, fn ->
      Pocket.Builder.resolve!([:pocket_missing_application])
    end
  end
end
