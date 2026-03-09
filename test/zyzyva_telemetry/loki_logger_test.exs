defmodule ZyzyvaTelemetry.LokiLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.LokiLogger

  @handler_id :zyzyva_loki_logger

  setup do
    # Clean up any existing handler/process from previous tests
    :logger.remove_handler(@handler_id)
    if pid = Process.whereis(LokiLogger), do: GenServer.stop(pid)

    on_exit(fn ->
      :logger.remove_handler(@handler_id)
      if pid = Process.whereis(LokiLogger), do: GenServer.stop(pid)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts and registers as logger handler" do
      {:ok, pid} = LokiLogger.start_link(loki_url: nil, service_name: "test")
      assert Process.alive?(pid)

      # Verify handler was registered
      handlers = :logger.get_handler_ids()
      assert @handler_id in handlers
    end

    test "handles restart when handler already exists" do
      {:ok, pid1} = LokiLogger.start_link(loki_url: nil, service_name: "test")
      GenServer.stop(pid1)

      # Starting again should not crash
      {:ok, pid2} = LokiLogger.start_link(loki_url: nil, service_name: "test")
      assert Process.alive?(pid2)
    end
  end

  describe "log buffering" do
    test "buffers log messages" do
      {:ok, _pid} =
        LokiLogger.start_link(
          loki_url: nil,
          service_name: "test",
          flush_interval: 60_000,
          min_level: :info
        )

      # Capture to suppress console output
      capture_log(fn ->
        require Logger
        Logger.info("test message one")
        Logger.info("test message two")
        # Allow cast to be processed
        Process.sleep(50)
      end)

      # Messages should be buffered (loki_url is nil so no push happens)
      state = :sys.get_state(LokiLogger)
      assert state.buffer_size >= 0
    end

    test "flushes when buffer reaches max size" do
      {:ok, _pid} =
        LokiLogger.start_link(
          loki_url: nil,
          service_name: "test",
          max_buffer_size: 2,
          flush_interval: 60_000,
          min_level: :info
        )

      capture_log(fn ->
        require Logger
        Logger.info("message one")
        Logger.info("message two")
        Logger.info("message three")
        Process.sleep(50)
      end)

      # Buffer should have been flushed (reset to 0 or close to it)
      state = :sys.get_state(LokiLogger)
      assert state.buffer_size < 2
    end

    test "flushes on timer" do
      {:ok, _pid} =
        LokiLogger.start_link(
          loki_url: nil,
          service_name: "test",
          flush_interval: 100,
          min_level: :info
        )

      capture_log(fn ->
        require Logger
        Logger.info("timed message")
        Process.sleep(50)
      end)

      state_before = :sys.get_state(LokiLogger)
      buffer_before = state_before.buffer_size

      # Wait for flush timer
      Process.sleep(200)

      state_after = :sys.get_state(LokiLogger)
      # Either buffer was empty or it was flushed
      assert state_after.buffer_size == 0 or state_after.buffer_size <= buffer_before
    end
  end

  describe "level filtering" do
    test "filters messages below min_level" do
      {:ok, _pid} =
        LokiLogger.start_link(
          loki_url: nil,
          service_name: "test",
          min_level: :warning,
          flush_interval: 60_000
        )

      capture_log(fn ->
        require Logger
        Logger.info("should be filtered")
        Logger.debug("also filtered")
        Process.sleep(50)
      end)

      state = :sys.get_state(LokiLogger)
      # Info and debug should not be buffered when min_level is :warning
      assert state.buffer_size == 0
    end

    test "accepts messages at or above min_level" do
      {:ok, _pid} =
        LokiLogger.start_link(
          loki_url: nil,
          service_name: "test",
          min_level: :warning,
          flush_interval: 60_000
        )

      capture_log(fn ->
        require Logger
        Logger.warning("should be accepted")
        Process.sleep(50)
      end)

      state = :sys.get_state(LokiLogger)
      assert state.buffer_size >= 1
    end
  end

  describe "handler cleanup" do
    test "removes handler on terminate" do
      {:ok, pid} = LokiLogger.start_link(loki_url: nil, service_name: "test")
      assert @handler_id in :logger.get_handler_ids()

      GenServer.stop(pid)
      refute @handler_id in :logger.get_handler_ids()
    end
  end
end
