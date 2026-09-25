defmodule PocketGPUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :pocket_gpui,
      version: "0.1.0",
      elixir: "~> 1.20",
      pocket: [main: PocketGPUI],
      deps: [
        {:gpui_native, "== 0.2.0"},
        {:pocket, path: "../..", runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
