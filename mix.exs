defmodule Pocket.MixProject do
  use Mix.Project

  @version "0.1.0-alpha.1"

  def project do
    [
      app: :pocket,
      version: @version,
      elixir: "~> 1.20",
      description: "Build single-executable Elixir CLIs with an experimental AOT BEAM",
      source_url: "https://github.com/jeregrine/pocket",
      homepage_url: "https://github.com/jeregrine/pocket",
      docs: [main: "readme", source_ref: "v#{@version}", extras: ["README.md", "CHANGELOG.md"]],
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/jeregrine/pocket"},
        files: ~w(lib priv mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
      ],
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
    [{:ex_doc, "~> 0.38", only: :dev, runtime: false}]
  end
end
