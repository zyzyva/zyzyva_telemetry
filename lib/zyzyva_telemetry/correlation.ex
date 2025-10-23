defmodule ZyzyvaTelemetry.Correlation do
  @moduledoc """
  Provides correlation ID tracking for distributed tracing.
  Correlation IDs allow tracking a single request across multiple services.
  """

  @correlation_key :zyzyva_telemetry_correlation_id

  @doc """
  Generates a new correlation ID in UUID v4 format.
  """
  def new do
    # Generate UUID v4
    <<a1::4, a2::4, a3::4, a4::4, a5::4, a6::4, a7::4, a8::4, b1::4, b2::4, b3::4, b4::4,
      _version::4, c1::4, c2::4, c3::4, _variant::2, d1::6, d2::4, d3::4, e1::4, e2::4, e3::4,
      e4::4, e5::4, e6::4, e7::4, e8::4, e9::4, e10::4, e11::4,
      e12::4>> = :crypto.strong_rand_bytes(16)

    # Set version to 4 and variant bits
    version = 4
    # RFC 4122 variant
    variant = 2

    <<a1::4, a2::4, a3::4, a4::4, a5::4, a6::4, a7::4, a8::4, b1::4, b2::4, b3::4, b4::4,
      version::4, c1::4, c2::4, c3::4, variant::2, d1::6, d2::4, d3::4, e1::4, e2::4, e3::4,
      e4::4, e5::4, e6::4, e7::4, e8::4, e9::4, e10::4, e11::4, e12::4>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  @doc """
  Executes a function with a specific correlation ID set.
  The correlation ID is automatically restored to its previous value after execution.
  """
  def with_correlation(correlation_id, fun) do
    previous = get()
    set(correlation_id)

    try do
      fun.()
    after
      if previous do
        set(previous)
      else
        clear()
      end
    end
  end

  @doc """
  Gets the current correlation ID from the process dictionary.
  Returns nil if no correlation ID is set.
  """
  def get do
    Process.get(@correlation_key)
  end

  @doc """
  Alias for get/0 - returns the current correlation ID.
  """
  def current do
    get()
  end

  @doc """
  Sets the correlation ID in the process dictionary.
  """
  def set(correlation_id) do
    Process.put(@correlation_key, correlation_id)
    :ok
  end

  @doc """
  Clears the correlation ID from the process dictionary.
  """
  def clear do
    Process.delete(@correlation_key)
    :ok
  end

  @doc """
  Gets the current correlation ID or generates a new one if not set.
  The generated ID is automatically set in the process dictionary.
  """
  def get_or_generate do
    case get() do
      nil ->
        correlation_id = new()
        set(correlation_id)
        correlation_id

      existing ->
        existing
    end
  end

  @doc """
  Adds the current correlation ID to a map or keyword list if one is set.
  If no correlation ID is set, returns the data unchanged.
  """
  def propagate(data) when is_map(data) do
    case get() do
      nil -> data
      correlation_id -> Map.put(data, :correlation_id, correlation_id)
    end
  end

  def propagate(data) when is_list(data) do
    case get() do
      nil -> data
      correlation_id -> Keyword.put(data, :correlation_id, correlation_id)
    end
  end

  # Private functions

  defp format_uuid(<<
         a1,
         a2,
         a3,
         a4,
         a5,
         a6,
         a7,
         a8,
         b1,
         b2,
         b3,
         b4,
         c1,
         c2,
         c3,
         c4,
         d1,
         d2,
         d3,
         d4,
         rest::binary
       >>) do
    "#{<<a1, a2, a3, a4, a5, a6, a7, a8>>}-" <>
      "#{<<b1, b2, b3, b4>>}-" <>
      "#{<<c1, c2, c3, c4>>}-" <>
      "#{<<d1, d2, d3, d4>>}-" <>
      "#{rest}"
  end
end
