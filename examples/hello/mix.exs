defmodule Hello.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello,
      version: "0.1.0",
      elixir: "~> 1.20",
      pocket: [main_module: Hello.CLI, shutdown_timeout: 250],
      deps: [{:pocket, path: "../..", runtime: false}]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {Hello.Application, []}]
end
