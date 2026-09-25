defmodule Pocket.MixProject do
  use Mix.Project

  def project do
    [
      app: :pocket,
      version: "0.1.0",
      elixir: "~> 1.20",
      description: "Build single-executable Elixir CLIs with an experimental AOT BEAM",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :sasl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end
end
