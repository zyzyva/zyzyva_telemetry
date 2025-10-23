defmodule ZyzyvaTelemetryV1Test do
  use ExUnit.Case
  import ExUnit.CaptureLog
  doctest ZyzyvaTelemetry

  describe "public API" do
    test "new_correlation_id/0 generates valid UUID v4" do
      id = ZyzyvaTelemetry.new_correlation_id()
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "get_correlation_id/0 returns nil when not set" do
      # Clear any existing correlation ID
      Process.delete(:zyzyva_telemetry_correlation_id)
      assert ZyzyvaTelemetry.get_correlation_id() == nil
    end

    test "set_correlation_id/1 and get_correlation_id/0 work together" do
      test_id = "test-correlation-123"
      assert :ok = ZyzyvaTelemetry.set_correlation_id(test_id)
      assert ZyzyvaTelemetry.get_correlation_id() == test_id
    end

    test "with_correlation/2 executes function with correlation ID" do
      test_id = "test-correlation-456"

      result =
        ZyzyvaTelemetry.with_correlation(test_id, fn ->
          assert ZyzyvaTelemetry.get_correlation_id() == test_id
          :success
        end)

      assert result == :success
      # Correlation ID should be cleared after
      assert ZyzyvaTelemetry.get_correlation_id() == nil
    end

    test "with_correlation/2 restores previous correlation ID" do
      original_id = "original-123"
      ZyzyvaTelemetry.set_correlation_id(original_id)

      ZyzyvaTelemetry.with_correlation("temporary-456", fn ->
        assert ZyzyvaTelemetry.get_correlation_id() == "temporary-456"
      end)

      assert ZyzyvaTelemetry.get_correlation_id() == original_id
    end

    test "get_health/0 returns health status" do
      # Start the supervisor first
      capture_log(fn ->
        {:ok, _pid} =
          ZyzyvaTelemetry.Supervisor.start_link(
            service_name: "test",
            promex_module: nil,
            repo: nil
          )

        send(self(), {:supervisor_started, :ok})
      end)

      assert_received {:supervisor_started, :ok}

      health = ZyzyvaTelemetry.get_health()
      assert is_map(health)
      assert health.status in ["healthy", "degraded", "warning", "critical", "starting"]
      assert health.service == "test"
    end

    test "report_health/2 registers custom health check" do
      capture_log(fn ->
        {:ok, _pid} =
          ZyzyvaTelemetry.Supervisor.start_link(
            service_name: "test",
            promex_module: nil,
            repo: nil
          )

        send(self(), {:supervisor_started, :ok})
      end)

      assert_received {:supervisor_started, :ok}

      # Report a custom health check
      ZyzyvaTelemetry.report_health(:custom_service, fn ->
        {:healthy, "All good"}
      end)

      # Give it time to register and run health check cycle (first check runs at 1000ms)
      Process.sleep(1100)

      health = ZyzyvaTelemetry.get_health()
      # Custom checks are merged directly into the health map
      assert health[:custom_service] == {:healthy, "All good"}
    end
  end

  describe "telemetry events" do
    test "track_operation/3 emits telemetry event" do
      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "test-handler-#{System.unique_integer()}",
            [:ecosystem, :business, :operation, :stop],
            fn event, measurements, metadata, _config ->
              send(self(), {:telemetry_event, event, measurements, metadata})
            end,
            nil
          )

        send(self(), {:handler_attached, :ok})
      end)

      assert_received {:handler_attached, :ok}

      ZyzyvaTelemetry.track_operation("test_service", :test_op, %{extra: "data"})

      assert_receive {:telemetry_event, [:ecosystem, :business, :operation, :stop], _measurements,
                      metadata}

      assert metadata.service_name == "test_service"
      assert metadata.operation == :test_op
      assert metadata.extra == "data"
    end

    test "track_error/2 emits error telemetry event" do
      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "test-error-handler-#{System.unique_integer()}",
            [:ecosystem, :error, :logged],
            fn event, measurements, metadata, _config ->
              send(self(), {:telemetry_event, event, measurements, metadata})
            end,
            nil
          )

        send(self(), {:handler_attached, :ok})
      end)

      assert_received {:handler_attached, :ok}

      ZyzyvaTelemetry.track_error("test_service", :test_error)

      assert_receive {:telemetry_event, [:ecosystem, :error, :logged], %{count: 1},
                      %{service_name: "test_service", kind: :test_error}}
    end

    test "track_deployment/2 emits deployment telemetry event" do
      capture_log(fn ->
        :ok =
          :telemetry.attach(
            "test-deployment-handler-#{System.unique_integer()}",
            [:ecosystem, :deployment, :completed],
            fn event, measurements, metadata, _config ->
              send(self(), {:telemetry_event, event, measurements, metadata})
            end,
            nil
          )

        send(self(), {:handler_attached, :ok})
      end)

      assert_received {:handler_attached, :ok}

      ZyzyvaTelemetry.track_deployment("test_service", :success)

      assert_receive {:telemetry_event, [:ecosystem, :deployment, :completed], %{count: 1},
                      %{service_name: "test_service", result: :success}}
    end
  end

  describe "Supervisor" do
    test "starts successfully with minimal config" do
      capture_log(fn ->
        assert {:ok, pid} =
                 ZyzyvaTelemetry.Supervisor.start_link(
                   service_name: "test",
                   promex_module: nil,
                   repo: nil
                 )

        assert Process.alive?(pid)
        Process.exit(pid, :normal)
      end)
    end

    test "starts health registry" do
      capture_log(fn ->
        {:ok, sup_pid} =
          ZyzyvaTelemetry.Supervisor.start_link(
            service_name: "test",
            promex_module: nil,
            repo: nil
          )

        # Health registry should be started
        assert Process.whereis(ZyzyvaTelemetry.Health.Registry) != nil

        Process.exit(sup_pid, :normal)
      end)
    end

    test "configures Tower when ErrorTracking is started" do
      # Tower configuration happens in ErrorTracking init
      # We can test that it sets up the reporters correctly
      capture_log(fn ->
        {:ok, _pid} = ZyzyvaTelemetry.ErrorTracking.start_link(service_name: "test_service")
        send(self(), {:error_tracking_started, :ok})
      end)

      assert_received {:error_tracking_started, :ok}

      # Tower should be configured with our reporter
      reporters = Application.get_env(:tower, :reporters)
      assert reporters == [ZyzyvaTelemetry.Reporters.StructuredFile]
    end
  end

  describe "Health.Registry" do
    setup do
      _log_output =
        capture_log(fn ->
          {:ok, pid} = ZyzyvaTelemetry.Health.Registry.start_link(service_name: "test")
          send(self(), {:registry_pid, pid})
        end)

      receive do
        {:registry_pid, pid} ->
          on_exit(fn ->
            if Process.alive?(pid), do: GenServer.stop(pid)
          end)

          {:ok, registry: pid}
      end
    end

    test "check_health returns starting status initially", %{registry: _registry} do
      # Give it a moment to initialize
      Process.sleep(10)
      health = ZyzyvaTelemetry.Health.Registry.check_health()
      assert health.status in ["starting", "healthy"]
      assert health.service == "test"
    end

    test "register_check adds custom health check", %{registry: _registry} do
      ZyzyvaTelemetry.Health.Registry.register_check(:custom, fn ->
        {:healthy, "Custom check passed"}
      end)

      # Wait for next check cycle (first check runs at 1000ms)
      Process.sleep(1100)

      health = ZyzyvaTelemetry.Health.Registry.check_health()
      # Custom checks are merged directly into the health map
      assert health[:custom] == {:healthy, "Custom check passed"}
    end
  end

  describe "Correlation module" do
    test "generates valid UUID v4" do
      id = ZyzyvaTelemetry.Correlation.new()
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "get/set/clear correlation ID" do
      # Clear first
      ZyzyvaTelemetry.Correlation.clear()
      assert ZyzyvaTelemetry.Correlation.get() == nil

      # Set and get
      ZyzyvaTelemetry.Correlation.set("test-123")
      assert ZyzyvaTelemetry.Correlation.get() == "test-123"

      # Clear
      ZyzyvaTelemetry.Correlation.clear()
      assert ZyzyvaTelemetry.Correlation.get() == nil
    end

    test "get_or_generate creates new ID if none exists" do
      ZyzyvaTelemetry.Correlation.clear()
      id1 = ZyzyvaTelemetry.Correlation.get_or_generate()
      assert id1 =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      # Should return same ID on second call
      id2 = ZyzyvaTelemetry.Correlation.get_or_generate()
      assert id1 == id2
    end

    test "propagate adds correlation ID to map" do
      ZyzyvaTelemetry.Correlation.set("test-456")
      data = %{foo: "bar"}
      result = ZyzyvaTelemetry.Correlation.propagate(data)
      assert result == %{foo: "bar", correlation_id: "test-456"}
    end

    test "propagate adds correlation ID to keyword list" do
      ZyzyvaTelemetry.Correlation.set("test-789")
      data = [foo: "bar"]
      result = ZyzyvaTelemetry.Correlation.propagate(data)
      # Keyword.put prepends new items
      assert result == [correlation_id: "test-789", foo: "bar"]
    end

    test "with_correlation executes function with temporary ID" do
      ZyzyvaTelemetry.Correlation.set("original")

      result =
        ZyzyvaTelemetry.Correlation.with_correlation("temporary", fn ->
          assert ZyzyvaTelemetry.Correlation.get() == "temporary"
          :done
        end)

      assert result == :done
      assert ZyzyvaTelemetry.Correlation.get() == "original"
    end
  end
end
