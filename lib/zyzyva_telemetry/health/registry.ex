defmodule ZyzyvaTelemetry.Health.Registry do
  @moduledoc """
  Registry for health checks that doesn't depend on SQLite.
  Provides in-memory health status tracking.
  """

  use GenServer
  require Logger

  # 30 seconds default
  @check_interval 30_000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check_health(_service_name \\ nil) do
    GenServer.call(__MODULE__, :get_health)
  catch
    :exit, _ ->
      %{
        status: "unknown",
        message: "Health registry not available",
        timestamp: DateTime.utc_now()
      }
  end

  def register_check(name, check_fun) do
    GenServer.cast(__MODULE__, {:register_check, name, check_fun})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    service_name = Keyword.get(opts, :service_name, get_service_name())
    check_interval = Keyword.get(opts, :check_interval, @check_interval)

    # Schedule first check
    Process.send_after(self(), :check_health, 1000)

    state = %{
      service_name: service_name,
      check_interval: check_interval,
      health_checks: %{},
      last_result: %{
        status: "starting",
        service: service_name,
        timestamp: DateTime.utc_now()
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_health, _from, state) do
    {:reply, state.last_result, state}
  end

  @impl true
  def handle_cast({:register_check, name, check_fun}, state) do
    health_checks = Map.put(state.health_checks, name, check_fun)
    {:noreply, %{state | health_checks: health_checks}}
  end

  @impl true
  def handle_info(:check_health, state) do
    # Run all health checks
    health_data = run_health_checks(state)

    # Schedule next check
    Process.send_after(self(), :check_health, state.check_interval)

    {:noreply, %{state | last_result: health_data}}
  end

  # Private functions

  defp run_health_checks(state) do
    # Always include basic checks
    memory = check_memory()
    processes = check_processes()

    # Run custom checks
    custom_results =
      state.health_checks
      |> Enum.map(fn {name, check_fun} ->
        {name, safe_run_check(check_fun)}
      end)
      |> Map.new()

    # Determine overall status
    overall_status = determine_overall_status(memory, processes, custom_results)

    %{
      status: overall_status,
      service: state.service_name,
      timestamp: DateTime.utc_now(),
      memory: memory,
      processes: processes[:count]
    }
    |> Map.merge(custom_results)
  end

  defp safe_run_check(check_fun) do
    check_fun.()
  rescue
    error ->
      Logger.warning("Health check failed: #{inspect(error)}")
      false
  end

  defp check_memory do
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024

    status =
      cond do
        memory_mb > 4096 -> :critical
        memory_mb > 2048 -> :warning
        true -> :ok
      end

    %{
      mb: Float.round(memory_mb, 2),
      status: status
    }
  end

  defp check_processes do
    count = length(Process.list())

    status =
      cond do
        count > 10_000 -> :critical
        count > 5_000 -> :warning
        true -> :ok
      end

    %{
      count: count,
      status: status
    }
  end

  defp determine_overall_status(memory, processes, custom_results) do
    all_statuses = [memory[:status], processes[:status]]

    # Check custom results (boolean values mean healthy if true)
    custom_ok =
      custom_results
      |> Map.values()
      |> Enum.all?(fn
        true -> true
        false -> false
        %{status: status} -> status in [:ok, :healthy]
        _ -> true
      end)

    cond do
      :critical in all_statuses -> "critical"
      not custom_ok -> "degraded"
      :warning in all_statuses -> "warning"
      true -> "healthy"
    end
  end

  defp get_service_name do
    cond do
      mix_app = get_mix_app_name() ->
        to_string(mix_app)

      otp_app = get_otp_app_name() ->
        to_string(otp_app)

      true ->
        "unknown"
    end
  end

  defp get_mix_app_name do
    case Mix.Project.get() do
      nil -> nil
      module -> module.project()[:app]
    end
  rescue
    _ -> nil
  end

  defp get_otp_app_name do
    case :application.get_application() do
      {:ok, app} -> app
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
