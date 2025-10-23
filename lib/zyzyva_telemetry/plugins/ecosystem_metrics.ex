defmodule ZyzyvaTelemetry.Plugins.EcosystemMetrics do
  @moduledoc """
  Common metrics for all Botify ecosystem applications.
  """

  use PromEx.Plugin

  import Telemetry.Metrics

  @impl true
  def event_metrics(_opts) do
    [
      counter(
        "ecosystem.deployment.count",
        event_name: [:ecosystem, :deployment, :completed],
        description: "Number of deployments",
        tags: [:service_name, :result]
      ),
      distribution(
        "ecosystem.business.duration",
        event_name: [:ecosystem, :business, :operation, :stop],
        description: "Business operation duration",
        tags: [:service_name, :operation],
        unit: {:native, :millisecond},
        buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
      ),
      counter(
        "ecosystem.error.count",
        event_name: [:ecosystem, :error, :logged],
        description: "Number of errors logged",
        tags: [:service_name, :kind]
      )
    ]
  end

  @impl true
  def polling_metrics(_opts) do
    # Polling metrics can be added later if needed
    # For now, focusing on event-based metrics
    []
  end
end
