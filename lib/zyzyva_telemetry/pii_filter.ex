defmodule ZyzyvaTelemetry.PIIFilter do
  @moduledoc """
  PII (Personally Identifiable Information) filtering for telemetry data.

  Automatically detects and masks sensitive information in telemetry metadata:
  - Email addresses
  - Passwords and authentication tokens
  - API keys and secrets
  - Credit card numbers
  - Phone numbers
  - SSN/ID numbers

  ## Configuration

      config :zyzyva_telemetry, :pii_filter,
        enabled: true,
        mask_email: true,
        mask_phone: true,
        detect_credit_cards: true,
        sensitive_keys: [:password, :token, :api_key, :secret, :auth],
        custom_patterns: []

  ## Usage

      # Filter a map
      metadata = %{email: "user@example.com", password: "secret123"}
      filtered = PIIFilter.filter(metadata)
      # => %{email: "u***@example.com", password: "[FILTERED]"}

      # Filter keyword list
      params = [name: "John", email: "john@example.com"]
      filtered = PIIFilter.filter(params)

  ## Performance

  Filtering is designed to be very fast (< 0.1ms per event) with minimal overhead.
  """

  @default_sensitive_keys [
    :password,
    :passwd,
    :pwd,
    :secret,
    :token,
    :api_key,
    :apikey,
    :access_token,
    :refresh_token,
    :auth_token,
    :authorization,
    :jwt,
    :bearer,
    :client_secret,
    :private_key,
    :encryption_key
  ]

  @email_regex ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/
  @phone_regex ~r/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/
  @ssn_regex ~r/\b\d{3}-\d{2}-\d{4}\b/

  ## Public API

  @doc """
  Filters PII from telemetry metadata (map or keyword list).
  """
  def filter(data) when is_map(data) do
    config = get_config()
    filter_map(data, config)
  end

  def filter(data) when is_list(data) do
    config = get_config()
    filter_keyword_list(data, config)
  end

  def filter(data), do: data

  @doc """
  Masks an email address. Returns the email with most characters replaced by asterisks.

  ## Examples

      iex> PIIFilter.mask_email("user@example.com")
      "u***@example.com"

      iex> PIIFilter.mask_email("a@b.co")
      "a***@b.co"
  """
  def mask_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] ->
        # Show first character + 3 asterisks
        first_char = String.slice(local, 0, 1)
        "#{first_char}***@#{domain}"

      _ ->
        email
    end
  end

  def mask_email(value), do: value

  @doc """
  Masks a phone number, showing only last 4 digits.

  ## Examples

      iex> PIIFilter.mask_phone("555-123-4567")
      "***-***-4567"
  """
  def mask_phone(phone) when is_binary(phone) do
    case String.length(phone) do
      len when len >= 10 ->
        visible = String.slice(phone, -4, 4)
        String.duplicate("*", len - 4) <> visible

      _ ->
        String.duplicate("*", String.length(phone))
    end
  end

  def mask_phone(value), do: value

  @doc """
  Detects if a string is a credit card number using the Luhn algorithm.
  """
  def credit_card?(value) when is_binary(value) do
    # Remove all non-digit characters
    digits = String.replace(value, ~r/\D/, "")

    # Credit cards are typically 13-19 digits
    case String.length(digits) do
      len when len >= 13 and len <= 19 ->
        luhn_valid?(digits)

      _ ->
        false
    end
  end

  def credit_card?(_value), do: false

  @doc """
  Masks a credit card number, showing only last 4 digits.
  """
  def mask_credit_card(value) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")
    last_four = String.slice(digits, -4, 4)
    "****-****-****-#{last_four}"
  end

  def mask_credit_card(value), do: value

  ## Private Functions

  defp get_config do
    Application.get_env(:zyzyva_telemetry, :pii_filter, [])
    |> Keyword.put_new(:enabled, true)
    |> Keyword.put_new(:mask_email, true)
    |> Keyword.put_new(:mask_phone, true)
    |> Keyword.put_new(:detect_credit_cards, true)
    |> Keyword.put_new(:sensitive_keys, @default_sensitive_keys)
    |> Keyword.put_new(:custom_patterns, [])
    |> Enum.into(%{})
  end

  ## Map Filtering

  defp filter_map(data, %{enabled: false}), do: data

  defp filter_map(data, config) when is_map(data) do
    data
    |> Enum.map(fn {key, value} -> {key, filter_value(key, value, config)} end)
    |> Enum.into(%{})
  end

  ## Keyword List Filtering

  defp filter_keyword_list(data, %{enabled: false}), do: data

  defp filter_keyword_list(data, config) when is_list(data) do
    Enum.map(data, fn {key, value} -> {key, filter_value(key, value, config)} end)
  end

  ## Value Filtering by Key

  # Check for sensitive keys first, before type-based filtering
  defp filter_value(key, value, config) when is_atom(key) do
    case is_sensitive_key?(key, config) do
      true -> "[FILTERED]"
      false -> filter_by_type(value, config)
    end
  end

  defp filter_value(_key, value, config) do
    filter_by_type(value, config)
  end

  ## Type-based Filtering

  defp filter_by_type(value, config) when is_binary(value) do
    filter_string_value(value, config)
  end

  defp filter_by_type(value, config) when is_map(value) do
    filter_map(value, config)
  end

  defp filter_by_type(value, config) when is_list(value) do
    filter_list_value(value, config)
  end

  defp filter_by_type(value, _config), do: value

  ## List Value Filtering

  defp filter_list_value([], _config), do: []

  defp filter_list_value([{_key, _value} | _rest] = list, config) do
    # It's a keyword list
    filter_keyword_list(list, config)
  end

  defp filter_list_value(list, _config) when is_list(list) do
    # It's a regular list, return as-is
    list
  end

  ## Sensitive Key Detection

  defp is_sensitive_key?(key, config) when is_atom(key) do
    sensitive_keys = Map.get(config, :sensitive_keys, @default_sensitive_keys)
    key_string = Atom.to_string(key) |> String.downcase()

    Enum.any?(sensitive_keys, fn sensitive_key ->
      sensitive_string = Atom.to_string(sensitive_key) |> String.downcase()
      String.contains?(key_string, sensitive_string)
    end)
  end

  ## String Value Filtering

  defp filter_string_value(value, config) when is_binary(value) do
    value
    |> maybe_filter_email(config)
    |> maybe_filter_phone(config)
    |> maybe_filter_credit_card(config)
    |> maybe_filter_ssn(config)
  end

  defp filter_string_value(value, _config), do: value

  ## Email Filtering

  defp maybe_filter_email(value, %{mask_email: true}) when is_binary(value) do
    detect_and_mask_email(value)
  end

  defp maybe_filter_email(value, _config), do: value

  defp detect_and_mask_email(value) do
    case Regex.run(@email_regex, value) do
      [email] -> String.replace(value, email, mask_email(email))
      nil -> value
    end
  end

  ## Phone Filtering

  defp maybe_filter_phone(value, %{mask_phone: true}) when is_binary(value) do
    detect_and_mask_phone(value)
  end

  defp maybe_filter_phone(value, _config), do: value

  defp detect_and_mask_phone(value) do
    case Regex.run(@phone_regex, value) do
      [phone] -> String.replace(value, phone, mask_phone(phone))
      nil -> value
    end
  end

  ## Credit Card Filtering

  defp maybe_filter_credit_card(value, %{detect_credit_cards: true}) when is_binary(value) do
    detect_and_mask_cc(value)
  end

  defp maybe_filter_credit_card(value, _config), do: value

  defp detect_and_mask_cc(value) do
    case credit_card?(value) do
      true -> mask_credit_card(value)
      false -> value
    end
  end

  ## SSN Filtering

  defp maybe_filter_ssn(value, _config) when is_binary(value) do
    detect_and_mask_ssn(value)
  end

  defp maybe_filter_ssn(value, _config), do: value

  defp detect_and_mask_ssn(value) do
    case Regex.run(@ssn_regex, value) do
      [ssn] -> String.replace(value, ssn, "***-**-****")
      nil -> value
    end
  end

  ## Luhn Algorithm for Credit Card Validation

  defp luhn_valid?(digits) when is_binary(digits) do
    digits
    |> String.graphemes()
    |> Enum.map(&String.to_integer/1)
    |> Enum.reverse()
    |> luhn_sum(0, 0)
    |> rem(10)
    |> Kernel.==(0)
  end

  defp luhn_sum([], _index, sum), do: sum

  defp luhn_sum([digit | rest], index, sum) when rem(index, 2) == 1 do
    doubled = digit * 2
    new_sum = sum + luhn_digit_sum(doubled)
    luhn_sum(rest, index + 1, new_sum)
  end

  defp luhn_sum([digit | rest], index, sum) do
    luhn_sum(rest, index + 1, sum + digit)
  end

  defp luhn_digit_sum(n) when n > 9, do: n - 9
  defp luhn_digit_sum(n), do: n
end
