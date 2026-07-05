defmodule ZyzyvaTelemetry.Correlation do
  @moduledoc """
  Provides correlation ID tracking for distributed tracing.
  Correlation IDs allow tracking a single request across multiple services.
  """

  @correlation_key :zyzyva_telemetry_correlation_id

  @doc """
  Generates a new correlation ID in UUID v4 format.
  """
  @spec new() :: String.t()
  def new do
    # UUID v4: 16 random bytes with the version nibble (4) and the RFC 4122
    # variant bits (0b10) set in their canonical positions.
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  @doc """
  Executes a function with a specific correlation ID set.
  The correlation ID is automatically restored to its previous value after execution.
  """
  @spec with_correlation(term(), (-> any())) :: any()
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
  @spec get() :: term()
  def get do
    Process.get(@correlation_key)
  end

  @doc """
  Alias for get/0 - returns the current correlation ID.
  """
  @spec current() :: term()
  def current do
    get()
  end

  @doc """
  Sets the correlation ID in the process dictionary.
  """
  @spec set(term()) :: :ok
  def set(correlation_id) do
    Process.put(@correlation_key, correlation_id)
    :ok
  end

  @doc """
  Clears the correlation ID from the process dictionary.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@correlation_key)
    :ok
  end

  @doc """
  Gets the current correlation ID or generates a new one if not set.
  The generated ID is automatically set in the process dictionary.
  """
  @spec get_or_generate() :: term()
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
  @spec propagate(map() | keyword()) :: map() | keyword()
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

  # Insert the canonical 8-4-4-4-12 hyphens into a 32-char hex string.
  defp format_uuid(<<
         group_a::binary-size(8),
         group_b::binary-size(4),
         group_c::binary-size(4),
         group_d::binary-size(4),
         group_e::binary-size(12)
       >>) do
    "#{group_a}-#{group_b}-#{group_c}-#{group_d}-#{group_e}"
  end
end
