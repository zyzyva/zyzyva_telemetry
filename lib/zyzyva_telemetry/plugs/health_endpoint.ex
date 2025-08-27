if Code.ensure_loaded?(Plug) do
  defmodule ZyzyvaTelemetry.Plugs.HealthEndpoint do
    @moduledoc """
    A plug that provides a health endpoint for your application.
  
  ## Usage
  
  Add to your router:
  
      # In your router.ex
      get "/health", ZyzyvaTelemetry.Plugs.HealthEndpoint, []
  
  Or use it in a pipeline:
  
      pipeline :health do
        plug ZyzyvaTelemetry.Plugs.HealthEndpoint
      end
      
      scope "/health" do
        pipe_through :health
        match :*, "/", ZyzyvaTelemetry.Plugs.HealthEndpoint, :handle
      end
  
  ## Options
  
    * `:path` - The path to match (defaults to "/health")
    * `:service_name` - Override the service name (defaults to auto-detected)
    * `:format` - Response format, either :full (default) or :simple
    * `:auth_fn` - Optional function to check authorization
  
  ## Response Formats
  
  ### Full format (default)
  Returns all telemetry data including memory, processes, database status, etc.
  
  ### Simple format
  Returns just `{"status": "ok"}` or `{"status": "error"}` for basic health checks.
  """
  
  import Plug.Conn
  
  def init(opts) do
    opts
  end
  
  def call(conn, opts) do
    path = opts[:path] || "/health"
    
    # Check if this is the health path
    if conn.request_path == path do
      # Check authorization if provided
      if check_auth(conn, opts[:auth_fn]) do
        send_health_response(conn, opts)
      else
        conn
        |> put_status(401)
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "Unauthorized"}))
        |> halt()
      end
    else
      conn
    end
  end
  
  # Alternative entry point for match routes
  def handle(conn, _params) do
    send_health_response(conn, [])
  end
  
  defp check_auth(_conn, nil), do: true
  defp check_auth(conn, auth_fn) when is_function(auth_fn, 1) do
    auth_fn.(conn)
  end
  defp check_auth(_conn, _), do: true
  
  defp send_health_response(conn, opts) do
    format = opts[:format] || :full
    service_name = opts[:service_name] || infer_service_name()
    
    {status_code, body} = case format do
      :simple ->
        build_simple_response()
      _ ->
        build_full_response(service_name)
    end
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, JSON.encode!(body))
    |> halt()
  end
  
  defp build_simple_response do
    case ZyzyvaTelemetry.AppMonitoring.get_health_status() do
      {:ok, %{status: status}} when status in [:healthy, :ok] ->
        {200, %{status: "ok"}}
      {:ok, %{status: :degraded}} ->
        {200, %{status: "degraded"}}
      _ ->
        {503, %{status: "error"}}
    end
  end
  
  defp build_full_response(service_name) do
    case ZyzyvaTelemetry.AppMonitoring.get_health_status() do
      {:ok, health_data} ->
        # Format the response
        body = format_health_data(health_data, service_name)
        
        # Determine HTTP status
        status_code = case health_data[:status] do
          :healthy -> 200
          :ok -> 200
          :degraded -> 200
          :critical -> 503
          _ -> 503
        end
        
        {status_code, body}
        
      {:error, _reason} ->
        # Fallback if monitoring not available
        {503, %{
          status: "error",
          service: to_string(service_name),
          message: "Monitoring system not available",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }}
    end
  end
  
  defp format_health_data(data, service_name) do
    %{
      status: to_string(data[:status] || :unknown),
      service: to_string(service_name),
      timestamp: format_timestamp(data[:timestamp]),
      memory: format_memory(data[:memory]),
      processes: data[:processes],
      database_connected: data[:database_connected],
      rabbitmq_connected: data[:rabbitmq_connected]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.merge(extract_custom_checks(data))
  end
  
  defp format_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(ts), do: to_string(ts)
  
  defp format_memory(nil), do: nil
  defp format_memory(%{mb: mb, status: status}) do
    %{
      mb: mb,
      status: to_string(status)
    }
  end
  defp format_memory(memory), do: memory
  
  defp extract_custom_checks(data) do
    # Extract any custom health checks that aren't standard fields
    standard_fields = [:status, :timestamp, :memory, :processes, 
                      :database_connected, :rabbitmq_connected, :message]
    
    data
    |> Enum.reject(fn {k, _v} -> k in standard_fields end)
    |> Map.new()
  end
  
  defp infer_service_name do
    # Try to get app name from Mix or OTP application
    cond do
      mix_app = get_mix_app_name() ->
        mix_app
      otp_app = get_otp_app_name() ->
        otp_app
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
end