defmodule ZyzyvaTelemetry.MixProject do
  use Mix.Project

  def project do
    [
      app: :zyzyva_telemetry,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Shared observability library wrapping Prometheus, Tower, and Loki for the Botify ecosystem",
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
      # Metrics (NEW)
      {:prom_ex, "~> 1.11"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Error tracking (NEW)
      {:tower, "~> 0.6"},

      # HTTP client for Loki
      {:req, "~> 0.4"},

      # Phoenix integration (KEEP)
      {:plug, "~> 1.18"},
      {:phoenix, "~> 1.7", optional: true},

      # Ecto integration (NEW - optional)
      {:ecto, "~> 3.10", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},

      # Broadway integration (NEW - optional)
      {:broadway, "~> 1.0", optional: true}

      # REMOVED: {:exqlite, "~> 0.33"} # No longer needed
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
