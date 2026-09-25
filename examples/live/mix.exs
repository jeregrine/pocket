defmodule Live.MixProject do
  use Mix.Project

  def project do
    [
      app: :live,
      version: "0.1.0",
      elixir: "~> 1.20",
      pocket: [main: Live.CLI, name: "pocket-live", console: true],
      deps: [{:pocket, path: "../..", runtime: false}]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {Live.Application, []}]
end
