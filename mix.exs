defmodule ZyzyvaTelemetry.MixProject do
  use Mix.Project

  def project do
    [
      app: :zyzyva_telemetry,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Lightweight monitoring library for distributed Elixir applications",
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exqlite, "~> 0.33"}
    ]
  end

  defp package do
    [
      name: "zyzyva_telemetry",
      files: ~w(lib .formatter.exs mix.exs README*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/zyzyva/zyzyva_telemetry"}
    ]
  end
end
