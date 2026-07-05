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
      # Define an inline health controller module with unique name. The response
      # logic lives in ZyzyvaTelemetry.PhoenixHealth so this generated module
      # stays thin.
      defmodule ZyzyvaTelemetryHealthController do
        @moduledoc false
        use Phoenix.Controller, namespace: false

        def health(conn, _params) do
          {status_code, body} = ZyzyvaTelemetry.PhoenixHealth.health_response(@health_format)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status_code, JSON.encode!(body))
        end
      end

      # Add the health route to the router
      scope @health_scope, as: false do
        if @health_pipeline do
          pipe_through(@health_pipeline)
        end

        get(@health_path, ZyzyvaTelemetryHealthController, :health)
      end
    end
  end

  @doc false
  @spec health_response(atom()) :: {pos_integer(), map()}
  def health_response(format) do
    # get_health_status/0 always returns {:ok, data}; the historical
    # {:error, _} branch was unreachable, so it is not carried over here.
    {:ok, health_data} = ZyzyvaTelemetry.AppMonitoring.get_health_status()
    format_response(format, health_data)
  end

  defp format_response(:simple, health_data), do: simple_response(health_data)
  defp format_response(_format, health_data), do: full_response(health_data)

  defp simple_response(health_data) do
    if health_data[:status] in [:healthy, :ok] do
      {200, %{status: "ok"}}
    else
      {503, %{status: to_string(health_data[:status])}}
    end
  end

  defp full_response(health_data) do
    {status_code(health_data[:status]), format_health_data(health_data)}
  end

  defp status_code(:healthy), do: 200
  defp status_code(:ok), do: 200
  defp status_code(:degraded), do: 200
  defp status_code(:critical), do: 503
  defp status_code(_), do: 503

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

  # NOTE (latent bug, behavior preserved): this historically called
  # Application.get_application(__MODULE__) and matched `{:ok, app}`, but that
  # function returns `atom() | nil`, so the match never succeeded and the
  # service name has always resolved to "unknown". Flagged for maintainers.
  defp get_service_name, do: "unknown"

  defp format_timestamp(nil), do: DateTime.to_iso8601(DateTime.utc_now())
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(ts), do: to_string(ts)

  defp format_memory(nil), do: nil
  defp format_memory(%{mb: mb, status: status}), do: %{mb: mb, status: to_string(status)}
  defp format_memory(memory), do: memory

  defp extract_custom_checks(data) do
    standard_fields = [
      :status,
      :timestamp,
      :memory,
      :processes,
      :database_connected,
      :rabbitmq_connected,
      :message
    ]

    data
    |> Enum.reject(fn {k, _v} -> k in standard_fields end)
    |> Map.new()
  end
end
