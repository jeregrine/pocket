defmodule TailnetDemo.CLI do
  @moduledoc false
  alias TailnetDemo.{Client, Identity, Server, Transport}

  def main(["--smoke"]) do
    # Calls a real NIF without enrollment, network access, or identity files.
    {} = Tailscale.Native.start_tracing()
    IO.puts("Static Tailscale NIF loaded")
    :ok
  end

  def main(argv) do
    config = parse!(argv)
    token = System.get_env("POCKET_DEMO_TOKEN", "")

    unless byte_size(token) in 32..1024,
      do:
        raise(ArgumentError, "set POCKET_DEMO_TOKEN to a random operator secret of 32–1024 bytes")

    System.delete_env("POCKET_DEMO_TOKEN")

    {transport, device} =
      if config.opts[:local] do
        {Transport.Loopback, nil}
      else
        role = if config.command == "serve", do: "server", else: "client"

        case Identity.connect(role, config.opts) do
          {:ok, device} ->
            {Transport.Tailnet, device}

          {:error, _} ->
            raise "Tailscale enrollment/connection failed; check your private identity and TS_AUTHKEY"
        end
      end

    case config.command do
      "serve" ->
        {:ok, server} =
          Server.start_link(
            transport: transport,
            device: device,
            token: token,
            port: config.port,
            allow_console: config.opts[:allow_console] || false
          )

        {ip, port} = Server.address(server)

        IO.puts(
          "Listening on #{:inet.ntoa(ip)}:#{port}; console #{if config.opts[:allow_console], do: "enabled", else: "disabled"}"
        )

        IO.puts("Counter runs only here. Ctrl-C stops this demo server.")
        Process.sleep(:infinity)

      "console" ->
        Client.console(transport, device, config.peer, config.port, token) |> finish()

      command ->
        fields = if command == "add", do: %{"amount" => config.amount}, else: %{}

        Client.request(transport, device, config.peer, config.port, token, command, fields)
        |> finish()
    end
  end

  def parse!(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          local: :boolean,
          peer: :string,
          port: :integer,
          state_dir: :string,
          hostname: :string,
          allow_console: :boolean
        ]
      )

    {command, amount} =
      case {args, invalid} do
        {["serve"], []} ->
          {"serve", nil}

        {["status"], []} ->
          {"status", nil}

        {["console"], []} ->
          {"console", nil}

        {["add", amount], []} ->
          case Integer.parse(amount) do
            {value, ""} when value in -1_000_000..1_000_000 -> {"add", value}
            _ -> usage!()
          end

        _ ->
          usage!()
      end

    port = opts[:port] || 4141
    minimum_port = if command == "serve", do: 0, else: 1
    unless port in minimum_port..65_535, do: usage!()
    if opts[:allow_console] && command != "serve", do: usage!()

    peer =
      cond do
        command == "serve" ->
          nil

        opts[:local] ->
          if opts[:peer] not in [nil, "127.0.0.1"], do: usage!()
          {127, 0, 0, 1}

        true ->
          case :inet.parse_address(String.to_charlist(opts[:peer] || "")) do
            {:ok, peer} -> peer
            _ -> raise ArgumentError, "provide --peer with the server's tailnet IP address"
          end
      end

    %{command: command, amount: amount, opts: opts, peer: peer, port: port}
  end

  defp finish({:ok, value}), do: IO.puts(JSON.encode!(value))
  defp finish(:ok), do: :ok
  defp finish({:error, message}) when is_binary(message), do: raise(message)
  defp finish({:error, _}), do: raise("connection failed or the server closed the session")

  defp usage! do
    raise ArgumentError, """
    Usage:
      tailnet-demo serve [--allow-console] [--port 4141]
      tailnet-demo status --peer TAILNET_IP
      tailnet-demo add NUMBER --peer TAILNET_IP
      tailnet-demo console --peer TAILNET_IP
      tailnet-demo --smoke
    Use --local for a loopback-only smoke test without joining a tailnet.
    """
  end
end
