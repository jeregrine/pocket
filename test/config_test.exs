defmodule Pocket.ConfigTest do
  use ExUnit.Case, async: true

  defp project(pocket \\ [main_module: Example.CLI]) do
    [app: :example, version: "0.1.0", pocket: pocket]
  end

  test "entry point, name, and shutdown deadline have explicit defaults" do
    assert %{main: Example.CLI, name: "example", shutdown_timeout: 5_000} =
             Pocket.Config.read!(project())

    assert %{name: "example-cli", shutdown_timeout: 250} =
             Pocket.Config.read!(
               project(main_module: Example.CLI, name: "example-cli", shutdown_timeout: 250)
             )
  end

  test "rejects missing entry points, unknown options, and unsafe filenames" do
    assert_raise Mix.Error, ~r/main_module/, fn -> Pocket.Config.read!(project([])) end

    assert_raise Mix.Error, ~r/Unknown/, fn ->
      Pocket.Config.read!(project(main_module: Example.CLI, tree_shake: true))
    end

    assert_raise Mix.Error, ~r/filename/, fn ->
      Pocket.Config.read!(project(main_module: Example.CLI, name: "../escape"))
    end

    for timeout <- [0, -1, :infinity, 60_001, "100"] do
      assert_raise Mix.Error, ~r/shutdown_timeout/, fn ->
        Pocket.Config.read!(project(main_module: Example.CLI, shutdown_timeout: timeout))
      end
    end
  end

  @tag :tmp_dir
  test "custom runtime configuration is rejected rather than silently ignored", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "runtime.exs"), "import Config")
    config = Keyword.put(project(), :config_path, Path.join(dir, "config.exs"))
    assert_raise Mix.Error, ~r/runtime.exs/, fn -> Pocket.Config.read!(config) end
  end

  test "custom releases and umbrellas cannot silently lose their configuration" do
    assert_raise Mix.Error, ~r/:releases/, fn ->
      Pocket.Config.read!(Keyword.put(project(), :releases, example: []))
    end

    assert_raise Mix.Error, ~r/non-umbrella/, fn ->
      Pocket.Config.read!(Keyword.put(project(), :apps_path, "apps"))
    end
  end
end
