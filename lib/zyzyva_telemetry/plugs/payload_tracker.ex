defmodule ZyzyvaTelemetry.Plugs.PayloadTracker do
  @moduledoc """
  Phoenix plug to track request and response payload sizes.

  Automatically measures:
  - Request body size (Content-Length header)
  - Response body size (calculated from response body)
  - Request type (static vs dynamic)
  - Alerts on large payloads

  ## Usage

  Add to your endpoint or router:

      plug ZyzyvaTelemetry.Plugs.PayloadTracker

  ## Configuration

      config :zyzyva_telemetry, :payload_tracker,
        enabled: true,
        large_payload_threshold_kb: 1000,    # 1MB
        track_static_requests: false         # Skip tracking static assets

  ## Resource Usage

  Minimal overhead:
  - No body parsing (uses Content-Length header)
  - No additional memory allocation
  - < 0.1ms per request
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = get_config()
    handle_tracking(config[:enabled], conn, config)
  end

  ## Tracking Logic

  defp handle_tracking(false, conn, _config), do: conn

  defp handle_tracking(true, conn, config) do
    start_time = System.monotonic_time()
    request_size = get_request_size(conn)
    request_type = classify_request(conn)

    # Skip static requests if configured
    case should_track?(request_type, config) do
      false ->
        conn

      true ->
        conn
        |> register_before_send(fn conn ->
          track_payload(conn, start_time, request_size, request_type, config)
        end)
    end
  end

  defp should_track?(:static, %{track_static_requests: false}), do: false
  defp should_track?(_type, _config), do: true

  defp track_payload(conn, start_time, request_size, request_type, config) do
    duration = System.monotonic_time() - start_time
    response_size = get_response_size(conn)

    metadata = %{
      request_size: request_size,
      response_size: response_size,
      request_type: request_type,
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      route: get_route(conn)
    }

    # Emit telemetry event
    :telemetry.execute(
      [:zyzyva, :phoenix, :payload],
      %{
        duration: duration,
        request_size: request_size,
        response_size: response_size
      },
      metadata
    )

    # Check for large payloads
    check_large_payload(request_size, response_size, metadata, config)

    conn
  end

  ## Size Calculation

  defp get_request_size(conn) do
    case get_req_header(conn, "content-length") do
      [size_str] -> String.to_integer(size_str)
      _ -> 0
    end
  end

  defp get_response_size(conn) do
    case get_resp_header(conn, "content-length") do
      [size_str] ->
        String.to_integer(size_str)

      _ ->
        # Estimate from response body if no header
        estimate_response_size(conn.resp_body)
    end
  end

  defp estimate_response_size(body) when is_binary(body), do: byte_size(body)
  defp estimate_response_size(body) when is_list(body), do: IO.iodata_length(body)
  defp estimate_response_size(_), do: 0

  ## Request Classification

  defp classify_request(conn) do
    path = conn.request_path

    cond do
      is_static_path?(path) -> :static
      is_api_path?(path) -> :api
      true -> :dynamic
    end
  end

  defp is_static_path?(path) do
    String.match?(path, ~r/\.(js|css|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot|map)$/i) ||
      String.starts_with?(path, "/assets/") ||
      String.starts_with?(path, "/images/") ||
      String.starts_with?(path, "/static/")
  end

  defp is_api_path?(path) do
    String.starts_with?(path, "/api/") ||
      String.starts_with?(path, "/graphql")
  end

  ## Large Payload Detection

  defp check_large_payload(request_size, response_size, metadata, config) do
    threshold_bytes = (config[:large_payload_threshold_kb] || 1000) * 1024

    cond do
      request_size > threshold_bytes ->
        log_large_payload(:request, request_size, metadata)

      response_size > threshold_bytes ->
        log_large_payload(:response, response_size, metadata)

      true ->
        :ok
    end
  end

  defp log_large_payload(type, size, metadata) do
    size_kb = div(size, 1024)

    Logger.warning(
      "Large #{type} payload detected: #{size_kb}KB on #{metadata.method} #{metadata.path}",
      payload_type: type,
      size_bytes: size,
      size_kb: size_kb,
      method: metadata.method,
      path: metadata.path,
      status: metadata.status
    )
  end

  ## Helpers

  defp get_route(conn) do
    case conn.private do
      %{phoenix_route: route} -> route
      _ -> conn.request_path
    end
  end

  defp get_config do
    Application.get_env(:zyzyva_telemetry, :payload_tracker, [])
    |> Keyword.put_new(:enabled, false)
    |> Keyword.put_new(:large_payload_threshold_kb, 1000)
    |> Keyword.put_new(:track_static_requests, false)
    |> Enum.into(%{})
  end
end
