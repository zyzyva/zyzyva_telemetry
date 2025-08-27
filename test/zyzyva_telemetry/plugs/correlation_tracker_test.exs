defmodule ZyzyvaTelemetry.Plugs.CorrelationTrackerTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias ZyzyvaTelemetry.Plugs.CorrelationTracker
  alias ZyzyvaTelemetry.Correlation

  setup do
    # Clear any existing correlation ID before each test
    Correlation.clear()

    # Create a test connection
    conn =
      %Plug.Conn{}
      |> Map.put(:req_headers, [])
      |> Map.put(:resp_headers, [])
      |> Map.put(:private, %{})

    {:ok, conn: conn}
  end

  describe "call/2" do
    test "generates new correlation ID when none exists", %{conn: conn} do
      conn = CorrelationTracker.call(conn, [])

      # Should have correlation ID in response header
      assert [correlation_id] = get_resp_header(conn, "x-correlation-id")

      assert String.match?(
               correlation_id,
               ~r/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
             )

      # Should be set in private
      assert conn.private[:correlation_id] == correlation_id

      # Should be set in process dictionary
      assert Correlation.get() == correlation_id
    end

    test "uses existing correlation ID from request header", %{conn: conn} do
      existing_id = "test-correlation-123"

      conn =
        conn
        |> Map.put(:req_headers, [{"x-correlation-id", existing_id}])

      conn = CorrelationTracker.call(conn, [])

      # Should preserve the existing ID
      assert [^existing_id] = get_resp_header(conn, "x-correlation-id")
      assert conn.private[:correlation_id] == existing_id
      assert Correlation.get() == existing_id
    end

    test "generates new ID when header value is empty", %{conn: conn} do
      conn =
        conn
        |> Map.put(:req_headers, [{"x-correlation-id", ""}])

      conn = CorrelationTracker.call(conn, [])

      # Should generate a new ID
      assert [correlation_id] = get_resp_header(conn, "x-correlation-id")
      assert correlation_id != ""

      assert String.match?(
               correlation_id,
               ~r/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
             )
    end

    test "uses first correlation ID when multiple headers exist", %{conn: conn} do
      conn =
        conn
        |> Map.put(:req_headers, [
          {"x-correlation-id", "first-id"},
          {"x-correlation-id", "second-id"}
        ])

      conn = CorrelationTracker.call(conn, [])

      # Should use the first ID
      assert [correlation_id] = get_resp_header(conn, "x-correlation-id")
      assert correlation_id == "first-id"
    end
  end

  describe "init/1" do
    test "returns options unchanged" do
      opts = [some: :option]
      assert CorrelationTracker.init(opts) == opts
    end
  end
end
