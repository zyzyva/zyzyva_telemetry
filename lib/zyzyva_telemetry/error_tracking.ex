defmodule ZyzyvaTelemetry.ErrorTracking do
  @moduledoc """
  Standardized Tower configuration for ecosystem apps.
  Configures Tower to write structured JSON logs for Loki ingestion.

  Tower v0.8+ doesn't use a supervision tree - it's configured via
  Application environment and attached to the logger.
  """

  use GenServer
  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)

    # Configure Tower reporters
    reporters = [
      [
        module: ZyzyvaTelemetry.Reporters.StructuredFile,
        service_name: service_name,
        log_path: "/var/log/#{service_name}/errors.json",
        format: :json
      ]
    ]

    # Configure Tower via application environment
    Application.put_env(:tower, :reporters, reporters)

    # Attach Tower to the logger
    :ok = Tower.attach()

    Logger.info("Tower error tracking configured for #{service_name}")

    {:ok, %{service_name: service_name}}
  end
end