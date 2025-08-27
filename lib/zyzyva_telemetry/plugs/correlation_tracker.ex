defmodule ZyzyvaTelemetry.Plugs.CorrelationTracker do
  @moduledoc """
  Plug for tracking correlation IDs across HTTP requests.

  This plug:
  - Extracts correlation ID from incoming request headers
  - Generates a new correlation ID if none exists
  - Sets the correlation ID in the process dictionary
  - Adds the correlation ID to response headers

  Usage in Phoenix router:

      pipeline :browser do
        # ... other plugs
        plug ZyzyvaTelemetry.Plugs.CorrelationTracker
      end
  """

  import Plug.Conn
  require Logger

  @correlation_header "x-correlation-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    correlation_id = extract_or_generate_correlation_id(conn)

    # Set in process dictionary for this request
    ZyzyvaTelemetry.Correlation.set(correlation_id)

    # Add to response headers
    conn
    |> put_resp_header(@correlation_header, correlation_id)
    |> put_private(:correlation_id, correlation_id)
  end

  defp extract_or_generate_correlation_id(conn) do
    case get_req_header(conn, @correlation_header) do
      [correlation_id | _] when is_binary(correlation_id) and correlation_id != "" ->
        correlation_id

      _ ->
        ZyzyvaTelemetry.Correlation.new()
    end
  end
end
