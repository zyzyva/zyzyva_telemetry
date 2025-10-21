defmodule ZyzyvaTelemetry.HealthController do
  @moduledoc """
  A ready-to-use Phoenix health controller.

  Simply reference this controller in your router:

      get "/health", ZyzyvaTelemetry.HealthController, :index

  Or if you need customization, copy this module and modify as needed.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    {status_code, body} = get_health_response()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status_code, JSON.encode!(body))
  end

  # Phoenix controller action
  def index(conn, _params) do
    call(conn, [])
  end

  defp get_health_response do
    {:ok, health_data} = ZyzyvaTelemetry.AppMonitoring.get_health_status()
    body = format_health_data(health_data)

    status_code =
      case health_data[:status] do
        :healthy -> 200
        :ok -> 200
        :degraded -> 200
        :critical -> 503
        _ -> 503
      end

    {status_code, body}
  end

  defp format_health_data(data) do
    # Start with standard fields
    base = %{
      status: to_string(data[:status] || :unknown),
      service: get_service_name(),
      timestamp: format_timestamp(data[:timestamp]),
      memory: format_memory(data[:memory]),
      processes: data[:processes],
      database_connected: data[:database_connected]
    }

    # Add ALL other fields from data (including custom ones like rabbitmq_connected)
    custom_fields =
      data
      |> Enum.reject(fn {k, _v} ->
        k in [:status, :timestamp, :memory, :processes, :database_connected, :message]
      end)
      |> Map.new()

    base
    |> Map.merge(custom_fields)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
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

  defp format_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(ts), do: to_string(ts)

  defp format_memory(nil), do: nil

  defp format_memory(%{mb: mb, status: status}) do
    %{mb: mb, status: to_string(status)}
  end

  defp format_memory(memory), do: memory
end
