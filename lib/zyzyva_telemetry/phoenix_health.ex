defmodule ZyzyvaTelemetry.PhoenixHealth do
  @moduledoc """
  Phoenix integration for health endpoints.
  
  Add health endpoints to your Phoenix router with one line.
  
  ## Usage
  
  In your router.ex:
  
      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        use ZyzyvaTelemetry.PhoenixHealth  # Add this line
        
        # Your pipelines and routes...
      end
  
  This automatically adds a `/health` endpoint to your application.
  
  ## Customization
  
  You can customize the path and options:
  
      use ZyzyvaTelemetry.PhoenixHealth, path: "/healthz", format: :simple
  
  ## Options
  
    * `:path` - The health endpoint path (default: "/health")
    * `:format` - Response format: `:full` (default) or `:simple`
    * `:pipeline` - Which pipeline to use (default: none, raw endpoint)
    * `:scope` - Scope to add the route to (default: "/")
  """
  
  defmacro __using__(opts \\ []) do
    path = Keyword.get(opts, :path, "/health")
    format = Keyword.get(opts, :format, :full)
    pipeline = Keyword.get(opts, :pipeline, nil)
    scope_path = Keyword.get(opts, :scope, "/")
    
    # Generate the controller module name based on the router module
    quote do
      # Import at compile time to make it available
      @before_compile ZyzyvaTelemetry.PhoenixHealth
      @health_opts unquote(Macro.escape(opts))
      @health_path unquote(path)
      @health_format unquote(format)
      @health_pipeline unquote(pipeline)
      @health_scope unquote(scope_path)
    end
  end
  
  defmacro __before_compile__(_env) do
    quote do
      # Define an inline health controller module with unique name
      defmodule ZyzyvaTelemetryHealthController do
        @moduledoc false
        use Phoenix.Controller, namespace: false
        
        def health(conn, _params) do
          {status_code, body} = get_health_response()
          
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status_code, JSON.encode!(body))
        end
        
        defp get_health_response do
          format = @health_format
          
          case ZyzyvaTelemetry.AppMonitoring.get_health_status() do
            {:ok, health_data} when format == :simple ->
              status = health_data[:status]
              if status in [:healthy, :ok] do
                {200, %{status: "ok"}}
              else
                {503, %{status: to_string(status)}}
              end
              
            {:ok, health_data} ->
              # Full format
              body = format_health_data(health_data)
              status_code = case health_data[:status] do
                :healthy -> 200
                :ok -> 200
                :degraded -> 200
                :critical -> 503
                _ -> 503
              end
              {status_code, body}
              
            {:error, _reason} ->
              {503, %{
                status: "error",
                message: "Monitoring system not available",
                timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
              }}
          end
        end
        
        defp format_health_data(data) do
          %{
            status: to_string(data[:status] || :unknown),
            service: get_service_name(),
            timestamp: format_timestamp(data[:timestamp]),
            memory: format_memory(data[:memory]),
            processes: data[:processes],
            database_connected: data[:database_connected]
          }
          |> Map.merge(extract_custom_checks(data))
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        end
        
        defp get_service_name do
          app = Application.get_application(__MODULE__)
          case app do
            {:ok, app_name} -> to_string(app_name)
            _ -> "unknown"
          end
        end
        
        defp format_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
        defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
        defp format_timestamp(ts), do: to_string(ts)
        
        defp format_memory(nil), do: nil
        defp format_memory(%{mb: mb, status: status}) do
          %{mb: mb, status: to_string(status)}
        end
        defp format_memory(memory), do: memory
        
        defp extract_custom_checks(data) do
          standard_fields = [:status, :timestamp, :memory, :processes, 
                            :database_connected, :rabbitmq_connected, :message]
          
          data
          |> Enum.reject(fn {k, _v} -> k in standard_fields end)
          |> Map.new()
        end
      end
      
      # Add the health route to the router
      scope @health_scope, as: false do
        if @health_pipeline do
          pipe_through @health_pipeline
        end
        
        get @health_path, ZyzyvaTelemetryHealthController, :health
      end
    end
  end
end