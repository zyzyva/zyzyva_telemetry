defmodule ZyzyvaTelemetry.TestHelpers do
  @moduledoc """
  Shared test helpers for testing ZyzyvaTelemetry integration in Phoenix apps.
  
  Add to your test by using this module:
  
      defmodule MyAppWeb.HealthControllerTest do
        use MyAppWeb.ConnCase
        use ZyzyvaTelemetry.TestHelpers
        
        test "health endpoint works", %{conn: conn} do
          assert_health_endpoint(conn, "/health")
        end
      end
  """
  
  defmacro __using__(_opts) do
    quote do
      import ZyzyvaTelemetry.TestHelpers
    end
  end
  
  @doc """
  Tests a health endpoint to ensure it returns proper telemetry data.
  
  ## Options
    * `:path` - The health endpoint path (defaults to "/health")
    * `:service_name` - Expected service name (optional, will check if present)
    * `:required_fields` - List of fields that must be present (defaults to standard fields)
  """
  def assert_health_endpoint(conn, path \\ "/health", opts \\ []) do
    import ExUnit.Assertions
    import Plug.Conn
    import Phoenix.ConnTest
    
    # Make request to health endpoint
    conn = get(conn, path)
    
    # Should return 200 OK or 503 for critical status
    assert conn.status in [200, 503]
    
    # Parse the JSON response
    body = json_response(conn, conn.status)
    
    # Verify standard fields
    assert body["status"] in ["healthy", "degraded", "critical", "unknown"]
    assert body["service"]
    assert body["timestamp"]
    
    # Check optional service name
    if service_name = opts[:service_name] do
      assert body["service"] == service_name
    end
    
    # Check telemetry-provided fields
    required_fields = opts[:required_fields] || ["memory", "processes", "database_connected"]
    
    for field <- required_fields do
      assert Map.has_key?(body, field), "Missing required field: #{field}"
    end
    
    # Verify memory structure if present
    if body["memory"] do
      assert body["memory"]["mb"], "Memory should have 'mb' field"
      assert body["memory"]["status"] in ["ok", "warning", "critical"],
             "Memory status should be ok, warning, or critical"
    end
    
    # Verify processes structure if present
    if body["processes"] do
      assert body["processes"]["count"], "Processes should have 'count' field"
      assert body["processes"]["status"] in ["ok", "warning", "critical"],
             "Processes status should be ok, warning, or critical"
    end
    
    body
  end
  
  @doc """
  Asserts that monitoring has been properly initialized for the app.
  """
  def assert_monitoring_initialized do
    import ExUnit.Assertions
    
    case ZyzyvaTelemetry.AppMonitoring.get_health_status() do
      {:ok, health_data} ->
        assert health_data[:status] in [:healthy, :degraded, :critical, :unknown]
        assert health_data[:memory]
        assert health_data[:processes]
        health_data
        
      {:error, reason} ->
        flunk("Monitoring not initialized: #{inspect(reason)}")
    end
  end
  
  @doc """
  Helper to test correlation ID tracking through a request.
  """
  def assert_correlation_tracking(conn, path \\ "/") do
    import ExUnit.Assertions
    import Plug.Conn
    import Phoenix.ConnTest
    
    # Make request
    conn = get(conn, path)
    
    # Check that correlation ID was set
    correlation_id = get_resp_header(conn, "x-correlation-id")
    assert correlation_id != []
    
    [cid] = correlation_id
    assert String.match?(cid, ~r/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i)
    
    cid
  end
end