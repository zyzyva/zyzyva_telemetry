defmodule ZyzyvaTelemetry.HealthReporter do
  @moduledoc """
  GenServer that periodically reports service health to the monitoring database.
  """

  use GenServer
  alias ZyzyvaTelemetry.SqliteWriter

  defstruct [
    :service_name,
    :node_id,
    :db_path,
    :interval_ms,
    :health_check_fn,
    :timer_ref,
    :last_health
  ]

  # 30 seconds
  @default_interval_ms 30_000

  @doc """
  Starts the health reporter process.

  Config options:
  - service_name: Name of the service (required)
  - node_id: Node identifier (required)
  - db_path: Path to SQLite database (required)
  - interval_ms: Reporting interval in milliseconds (default: 30000)
  - health_check_fn: Function that returns health data map (optional)
  """
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Manually reports health status.
  """
  def report_health(pid, health_data) do
    GenServer.cast(pid, {:report_health, health_data})
  end

  @doc """
  Gets the current health status.
  """
  def get_current_health(pid) do
    GenServer.call(pid, :get_current_health)
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{
      service_name: config.service_name,
      node_id: config.node_id,
      db_path: config.db_path,
      interval_ms: config[:interval_ms] || @default_interval_ms,
      health_check_fn: config[:health_check_fn] || (&default_health_check/0),
      last_health: nil
    }

    # Schedule first health report
    timer_ref = schedule_health_check(state.interval_ms)

    # Report initial health immediately
    send(self(), :perform_health_check)

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast({:report_health, health_data}, state) do
    write_health_event(state, health_data)
    {:noreply, %{state | last_health: health_data}}
  end

  @impl true
  def handle_call(:get_current_health, _from, state) do
    # If we don't have cached health, generate it now
    health = state.last_health || state.health_check_fn.()
    {:reply, health, state}
  end

  @impl true
  def handle_info(:perform_health_check, state) do
    # Get health status from configured function
    health_data = state.health_check_fn.()

    # Write to database
    write_health_event(state, health_data)

    # Schedule next check
    timer_ref = schedule_health_check(state.interval_ms)

    {:noreply, %{state | timer_ref: timer_ref, last_health: health_data}}
  end

  # Private functions

  defp schedule_health_check(interval_ms) do
    Process.send_after(self(), :perform_health_check, interval_ms)
  end

  defp write_health_event(state, health_data) do
    severity =
      case health_data[:status] || health_data.status do
        :healthy -> "info"
        :degraded -> "warning"
        :unhealthy -> "error"
        _ -> "info"
      end

    message = build_health_message(health_data)

    # Convert atoms to strings in metadata for JSON encoding
    metadata = stringify_metadata(health_data)

    event = %{
      service_name: state.service_name,
      node_id: state.node_id,
      event_type: "health",
      severity: severity,
      message: message,
      correlation_id: nil,
      metadata: metadata
    }

    SqliteWriter.write_event(state.db_path, event)
  end

  defp build_health_message(health_data) do
    status = health_data[:status] || health_data.status || :unknown

    case status do
      :healthy ->
        "Service is healthy"

      :degraded ->
        "Service is degraded: #{health_data[:reason] || health_data.reason || "Unknown reason"}"

      :unhealthy ->
        "Service is unhealthy: #{health_data[:error] || health_data.error || "Unknown error"}"

      _ ->
        "Health status: #{status}"
    end
  end

  defp stringify_metadata(map) when is_map(map) do
    map
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
    |> Enum.into(%{})
  end

  defp stringify_metadata(other), do: other

  defp stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_struct(v), do: Map.from_struct(v) |> stringify_metadata()
  defp stringify_value(v) when is_map(v), do: stringify_metadata(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  defp default_health_check do
    # Basic health check - just report healthy with system metrics
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024

    %{
      status: :healthy,
      memory_mb: Float.round(memory_mb, 2),
      processes: :erlang.system_info(:process_count),
      uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    }
  end
end
