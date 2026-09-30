defmodule TailnetDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :tailnet_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      pocket: [main: TailnetDemo.CLI, name: "tailnet-demo", console: :embedded],
      deps: [
        {:pocket, path: "../..", runtime: false},
        {:tailscale, "== 0.6.1"}
      ]
    ]
  end

  # The counter and listener start only in `serve`, never in a client command.
  def application, do: [extra_applications: [:logger, :crypto, :iex]]
end
