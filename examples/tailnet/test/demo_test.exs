defmodule TailnetDemoTest do
  use ExUnit.Case
  alias TailnetDemo.{Client, Counter, Server, Wire}
  alias TailnetDemo.Transport.Loopback
  @token String.duplicate("demo-test-not-a-real-secret-", 2)

  @moduletag timeout: 15_000

  setup context do
    server =
      start_supervised!(
        {Server,
         transport: Loopback, token: @token, port: 0, allow_console: !context[:console_disabled]}
      )

    {ip, port} = Server.address(server)
    %{server: server, ip: ip, port: port}
  end

  test "commands reach the existing counter without BEAM distribution", ctx do
    original = Process.whereis(Counter)
    assert {:ok, %{"value" => 0}} = request(ctx, "status")
    assert {:ok, %{"value" => 7}} = request(ctx, "add", %{"amount" => 7})
    assert Process.whereis(Counter) == original
    assert node() == :nonode@nohost
    assert Node.list() == []
  end

  test "supervision specs do not retain the plaintext operator token", ctx do
    assert {:ok, %{start: {_, _, [opts]}}} =
             :supervisor.get_childspec(ctx.server, TailnetDemo.Listener)

    refute Keyword.has_key?(opts, :token)
    assert opts[:token_hash] == :crypto.hash(:sha256, @token)
  end

  test "wrong credentials cannot mutate state", ctx do
    assert {:error, "unauthorized"} =
             Client.request(Loopback, nil, ctx.ip, ctx.port, "wrong", "add", %{"amount" => 10})

    assert Counter.status()["value"] == 0
  end

  @tag :console_disabled
  test "console is independently disabled even for an authenticated operator", ctx do
    assert {:error, "console is disabled"} = request(ctx, "console")
    assert {:ok, %{"value" => 0}} = request(ctx, "status")
  end

  test "a real IEx session can change server state and detach without stopping the app", ctx do
    {:ok, socket} = Loopback.connect(nil, ctx.ip, ctx.port)

    :ok =
      Wire.send(Loopback, socket, %{"version" => 1, "token" => @token, "command" => "console"})

    {banner, buffer} = until_input(socket, <<>>, "")
    assert banner =~ "Remote IEx"

    :ok =
      Wire.send(Loopback, socket, %{"type" => "line", "data" => "TailnetDemo.Counter.add(42)\n"})

    {output, buffer} = until_input(socket, buffer, "")
    assert output =~ "42"
    assert Counter.status()["value"] == 42
    :ok = Wire.send(Loopback, socket, %{"type" => "line", "data" => "x = 20\n"})
    {_, buffer} = until_input(socket, buffer, "")
    :ok = Wire.send(Loopback, socket, %{"type" => "line", "data" => "x + 2\n"})
    {output, buffer} = until_input(socket, buffer, "")
    assert output =~ "22"
    :ok = Wire.send(Loopback, socket, %{"type" => "line", "data" => "Enum.map([1, 2], fn x ->\n"})
    {_, buffer} = until_input(socket, buffer, "")
    :ok = Wire.send(Loopback, socket, %{"type" => "line", "data" => "x * 3 end)\n"})
    {output, _} = until_input(socket, buffer, "")
    assert Regex.replace(~r/\e\[[0-9;]*m/, output, "") =~ "[3, 6]"
    :ok = Wire.send(Loopback, socket, %{"type" => "detach"})
    assert {:error, :closed} = Wire.recv(Loopback, socket)
    assert {:ok, %{"value" => 42}} = request(ctx, "status")
  end

  test "closing an idle console does not terminate the service", ctx do
    {:ok, socket} = Loopback.connect(nil, ctx.ip, ctx.port)

    :ok =
      Wire.send(Loopback, socket, %{"version" => 1, "token" => @token, "command" => "console"})

    until_input(socket, <<>>, "")
    :ok = Loopback.close(socket)
    assert {:ok, %{"value" => 0}} = request(ctx, "status")
  end

  test "authentication tolerates arbitrary TCP fragmentation", ctx do
    {:ok, socket} = Loopback.connect(nil, ctx.ip, ctx.port)
    data = JSON.encode!(%{"version" => 1, "token" => @token, "command" => "status"})
    frame = <<byte_size(data)::32, data::binary>>

    for <<byte <- frame>> do
      :ok = Loopback.send(socket, <<byte>>)
    end

    assert {:ok, %{"type" => "result", "value" => %{"value" => 0}}, _} =
             Wire.recv(Loopback, socket)

    Loopback.close(socket)
  end

  test "unsupported commands are not arbitrary remote function calls", ctx do
    assert {:error, "unsupported command"} = request(ctx, "System.halt")
    assert {:error, "unsupported command"} = request(ctx, "add", %{"amount" => "atom"})
  end

  test "oversized and malformed packets fail closed", ctx do
    {:ok, socket} = Loopback.connect(nil, ctx.ip, ctx.port)
    :ok = Loopback.send(socket, <<Wire.limit() + 1::32>>)
    assert {:error, :closed} = Wire.recv(Loopback, socket)
    assert {:error, :invalid_message} = Wire.decode(<<4::32, "nope">>)
    assert {:error, :invalid_message} = Wire.decode(<<2::32, "[]">>)
  end

  test "wire decoder retains coalesced frames and waits for fragments" do
    message = JSON.encode!(%{"hello" => "λ"})
    frame = <<byte_size(message)::32, message::binary>>
    assert :more == Wire.decode(binary_part(frame, 0, 5))
    assert {:ok, %{"hello" => "λ"}, ^frame} = Wire.decode(frame <> frame)
  end

  test "loopback mode cannot accidentally connect to another host" do
    assert {:error, :loopback_only} = Loopback.connect(nil, {8, 8, 8, 8}, 4141)

    assert_raise ArgumentError, fn ->
      TailnetDemo.CLI.parse!(["status", "--local", "--peer", "8.8.8.8"])
    end

    assert_raise ArgumentError, fn -> TailnetDemo.CLI.parse!(["status"]) end
  end

  @tag :tmp_dir
  test "identity directories cannot be public or symlinks", %{tmp_dir: directory} do
    private = Path.join(directory, "private")
    assert :ok = TailnetDemo.Identity.prepare!(private)
    assert :ok = TailnetDemo.Identity.prepare!(private)
    File.chmod!(private, 0o755)
    assert_raise ArgumentError, fn -> TailnetDemo.Identity.prepare!(private) end
    link = Path.join(directory, "link")
    File.ln_s!(private, link)
    assert_raise ArgumentError, fn -> TailnetDemo.Identity.prepare!(link) end
  end

  defp request(ctx, command, fields \\ %{}),
    do: Client.request(Loopback, nil, ctx.ip, ctx.port, @token, command, fields)

  defp until_input(socket, buffer, output) do
    case Wire.recv(Loopback, socket, buffer) do
      {:ok, %{"type" => "input"}, rest} ->
        {output, rest}

      {:ok, %{"type" => "console", "message" => data}, rest} ->
        until_input(socket, rest, output <> data)

      {:ok, %{"type" => "output", "data" => data}, rest} ->
        until_input(socket, rest, output <> data)

      other ->
        flunk("Unexpected console frame: #{inspect(other)}")
    end
  end
end
