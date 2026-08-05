defmodule OpenPair.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_pair,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end

  # `mix escript.build` produces a single executable `openpair` file —
  # matches how JaVaFo is distributed (one runnable artifact you point a TRF
  # file at), rather than requiring `mix run` or a full release.
  defp escript do
    [
      main_module: OpenPair.CLI,
      name: "openpair"
    ]
  end
end
