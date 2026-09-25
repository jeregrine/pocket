defmodule PocketGPUI.Test do
  use GPUI.Test, async: true

  test "counter updates and closing the last window empties the session" do
    runtime = start_runtime!(PocketGPUI.Desktop)
    assert %{count: 0} = assigns(runtime)
    click(runtime, "increment")
    assert %{count: 1} = assigns(runtime)
    assert {:ok, %{windows: []}} = GPUI.Runtime.close_window(runtime, 1)
  end
end
