defmodule ZyzyvaTelemetry do
  @moduledoc """
  ZyzyvaTelemetry v1.0 - Shared observability library for the Botify ecosystem.

  This library wraps industry-standard tools (Prometheus, Tower, Loki) to provide:
  - Metrics collection via PromEx
  - Error tracking via Tower
  - Structured logging for Loki
  - Health check endpoints
  - Correlation ID tracking for distributed tracing

  ## Usage

  Add to your application's supervision tree:

      children = [
        # ... other children
        {ZyzyvaTelemetry.Supervisor,
         service_name: "my_app",
         promex_module: MyApp.PromEx,
         repo: MyApp.Repo}
      ]

  Define your PromEx module:

      defmodule MyApp.PromEx do
        use ZyzyvaTelemetry.PromEx,
          otp_app: :my_app,
          service_name: "my_app",
          router: MyAppWeb.Router,
          repos: [MyApp.Repo]
      end

  Then use throughout your application:

      # Track correlation across services
      ZyzyvaTelemetry.with_correlation(correlation_id, fn ->
        # Your code here - all logs will include correlation_id
      end)

      # Emit custom metrics
      :telemetry.execute([:ecosystem, :business, :operation, :stop], %{duration: 100}, %{
        service_name: "my_app",
        operation: "process_payment"
      })
  """

  alias ZyzyvaTelemetry.{Correlation, AppMonitoring}

  @doc """
  Gets the current health status.
  Returns the most recent health check data from the registry.
  """
  def get_health do
    case AppMonitoring.get_health_status() do
      {:ok, data} -> data
      _ -> %{status: "unknown", message: "Health check unavailable"}
    end
  end

  @doc """
  Manually reports health status.
  Registers a custom health check with the registry.
  """
  def report_health(name, check_fun) when is_atom(name) and is_function(check_fun, 0) do
    ZyzyvaTelemetry.Health.Registry.register_check(name, check_fun)
  end

  @doc """
  Executes a function with a correlation ID set.
  The correlation ID will be included in all logs and errors within the function.
  """
  defdelegate with_correlation(correlation_id, fun), to: Correlation

  @doc """
  Gets the current correlation ID.
  """
  defdelegate get_correlation_id, to: Correlation, as: :current

  @doc """
  Sets the correlation ID for the current process.
  """
  defdelegate set_correlation_id(correlation_id), to: Correlation, as: :set

  @doc """
  Generates a new correlation ID.
  """
  defdelegate new_correlation_id, to: Correlation, as: :new

  @doc """
  Emits a deployment event for metrics tracking.
  """
  def track_deployment(service_name, result \\ :success) do
    :telemetry.execute(
      [:ecosystem, :deployment, :completed],
      %{count: 1},
      %{service_name: service_name, result: result}
    )
  end

  @doc """
  Tracks a business operation duration.
  Use with :telemetry.span/3 for automatic timing.
  """
  def track_operation(service_name, operation, metadata \\ %{}) do
    start_metadata = Map.merge(metadata, %{service_name: service_name, operation: operation})

    :telemetry.span(
      [:ecosystem, :business, :operation],
      start_metadata,
      fn ->
        # The actual operation would go here
        {:ok, start_metadata}
      end
    )
  end

  @doc """
  Emits an error event for metrics tracking.
  """
  def track_error(service_name, kind) do
    :telemetry.execute(
      [:ecosystem, :error, :logged],
      %{count: 1},
      %{service_name: service_name, kind: kind}
    )
  end
end
