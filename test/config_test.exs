defmodule Pocket.ConfigTest do
  use ExUnit.Case, async: true

  defp project(pocket \\ [main: Example.CLI]) do
    [app: :example, version: "0.1.0", pocket: pocket]
  end

  test "console is explicitly opt-in and boolean" do
    assert %{console: false} = Pocket.Config.read!(project())
    assert %{console: true} = Pocket.Config.read!(project(main: Example.CLI, console: true))

    for console <- [nil, :iex, "true", []] do
      assert_raise Mix.Error, ~r/:console must be a boolean/, fn ->
        Pocket.Config.read!(project(main: Example.CLI, console: console))
      end
    end
  end

  test "entry point, name, and shutdown deadline have explicit defaults" do
    assert %{main: Example.CLI, name: "example", shutdown_timeout: 5_000} =
             Pocket.Config.read!(project())

    assert %{name: "example-cli", shutdown_timeout: 250} =
             Pocket.Config.read!(
               project(main: Example.CLI, name: "example-cli", shutdown_timeout: 250)
             )
  end

  test "rejects missing entry points, unknown options, and unsafe filenames" do
    assert_raise Mix.Error, ~r/main:/, fn -> Pocket.Config.read!(project([])) end

    assert_raise Mix.Error, ~r/Unknown/, fn ->
      Pocket.Config.read!(project(main: Example.CLI, tree_shake: true))
    end

    assert_raise Mix.Error, ~r/filename/, fn ->
      Pocket.Config.read!(project(main: Example.CLI, name: "../escape"))
    end

    for timeout <- [0, -1, :infinity, 60_001, "100"] do
      assert_raise Mix.Error, ~r/shutdown_timeout/, fn ->
        Pocket.Config.read!(project(main: Example.CLI, shutdown_timeout: timeout))
      end
    end
  end

  test "accepts MFAs with zero or multiple additional arguments" do
    for main <- [{Example.CLI, :run, []}, {Example.CLI, :run, ["prefix", %{option: true}]}] do
      assert %{main: ^main} = Pocket.Config.read!(project(main: main))
    end
  end

  test "rejects malformed MFAs before building" do
    for main <- [
          {nil, :run, []},
          {Example.CLI, "run", []},
          {Example.CLI, :run, :not_a_list},
          {Example.CLI, :run, [1 | 2]},
          {Example.CLI, :run, List.duplicate(:arg, 255)},
          {Example.CLI, :run, List.duplicate(:arg, 256)},
          {Example.CLI, :run},
          {Example.CLI, :run, [], :extra}
        ] do
      assert_raise Mix.Error, ~r/main:/, fn -> Pocket.Config.read!(project(main: main)) end
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
