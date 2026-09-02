defmodule Ainalrami.MixProject do
  use Mix.Project

  @version "0.15.0"
  @source_url "https://github.com/AuroraRyunix/Ainalrami"

  def project do
    [
      app: :ainalrami,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: escript(),
      name: "Ainalrami",
      description: "A FIDE Dutch-system Swiss pairing engine, written in Elixir.",
      source_url: @source_url,
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/architecture.md",
          "docs/validation.md",
          "docs/conformance-c0403-2026.md",
          "docs/fide-criteria.md",
          "docs/engineering-log.md"
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end

  # `mix escript.build` produces a single executable `ainalrami` file -
  # matches how JaVaFo is distributed (one runnable artifact you point a TRF
  # file at), rather than requiring `mix run` or a full release.
  defp escript do
    [
      main_module: Ainalrami.CLI,
      name: "ainalrami"
    ]
  end
end
