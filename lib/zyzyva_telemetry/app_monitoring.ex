defmodule ZyzyvaTelemetry.AppMonitoring do
  @moduledoc """
  Simplified monitoring setup for Phoenix applications.
  Provides standard health checks and DRY initialization.
  """

  @doc """
  Get the current health status for use in health endpoints.
  Returns the most recent health check data.
  """
  def get_health_status do
    health_data = ZyzyvaTelemetry.Health.Registry.check_health()
    {:ok, health_data}
  end

  @doc """
  Standard database health check using Ecto repo.
  """
  def check_database(nil), do: nil

  def check_database(repo) do
    try do
      repo.query!("SELECT 1")
      true
    rescue
      _ -> false
    end
  end

  @doc """
  Standard memory health check.
  Returns memory in MB and a status indicator.
  """
  def check_memory do
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024

    # Simple thresholds - could be made configurable
    status =
      cond do
        # > 4GB
        memory_mb > 4096 -> :critical
        # > 2GB
        memory_mb > 2048 -> :warning
        true -> :ok
      end

    %{
      mb: Float.round(memory_mb, 2),
      status: status
    }
  end

  @doc """
  Standard process count health check.
  """
  def check_processes do
    count = length(Process.list())

    # Simple thresholds
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

  @doc """
  Check if a named GenServer/Broadway pipeline is running.
  """
  def check_process(process_name) do
    case Process.whereis(process_name) do
      nil -> false
      _pid -> true
    end
  end
end
