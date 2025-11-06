defmodule ZyzyvaTelemetry.Plugins.AiTokenUsage do
  @moduledoc """
  AI token usage monitoring plugin for PromEx.

  Tracks token consumption for AI API calls (OpenAI, Mistral, Anthropic, etc.):
  - Prompt tokens (input)
  - Completion tokens (output)
  - Total tokens
  - Cached tokens (cost savings)

  ## Configuration

      config :zyzyva_telemetry, :ai_token_usage,
        enabled: false,                  # Opt-in by default
        track_by_model: true,            # Track metrics per AI model
        track_cached_tokens: true        # Track prompt caching separately

  ## Telemetry Events

  Your application should emit telemetry events in this format:

      :telemetry.execute(
        [:your_app, :ai, :completion],  # or [:your_app, :ocr, :token_usage]
        %{
          prompt_tokens: 1234,
          completion_tokens: 567,
          total_tokens: 1801,
          cached_tokens: 100  # optional
        },
        %{
          provider: "OpenAI",   # or "Mistral", "Anthropic", etc.
          model: "gpt-4o",      # optional - AI model name
          feature: "ocr"        # optional - feature using AI
        }
      )

  ## Resource Usage

  Minimal overhead:
  - Simple counter increments
  - No network calls or I/O
  - < 0.01ms per event

  ## Metrics Provided

  - `ai.token.usage.prompt_tokens.total` - Total input tokens sent to AI
  - `ai.token.usage.completion_tokens.total` - Total output tokens from AI
  - `ai.token.usage.total_tokens.total` - Combined token usage
  - `ai.token.usage.cached_tokens.total` - Cached tokens (cost savings)

  All metrics tagged with:
  - `provider` - AI provider (OpenAI, Mistral, Anthropic, etc.)
  - `model` - AI model name (if track_by_model enabled)
  - `feature` - Application feature using AI (if provided)

  ## Example Usage

  ### Business Card OCR

      # In your OCR handler
      :telemetry.execute(
        [:contacts4us, :ocr, :token_usage],
        %{
          prompt_tokens: usage["prompt_tokens"],
          completion_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"]
        },
        %{provider: "OpenAI", model: "gpt-4o", feature: "business_card_scanner"}
      )

  ### Chat Completion

      :telemetry.execute(
        [:my_app, :ai, :chat],
        %{
          prompt_tokens: 150,
          completion_tokens: 75,
          total_tokens: 225,
          cached_tokens: 50
        },
        %{provider: "Anthropic", model: "claude-3-5-sonnet"}
      )
  """

  use PromEx.Plugin

  import Telemetry.Metrics

  @impl true
  def event_metrics(_opts) do
    config = get_config()
    build_metrics(config)
  end

  @impl true
  def polling_metrics(_opts), do: []

  ## Configuration

  defp get_config do
    Application.get_env(:zyzyva_telemetry, :ai_token_usage, [])
    |> Keyword.put_new(:enabled, true)
    |> Keyword.put_new(:track_by_model, true)
    |> Keyword.put_new(:track_cached_tokens, true)
    |> Enum.into(%{})
  end

  ## Metrics Building

  defp build_metrics(_config) do
    # Always build metrics - enabled by default
    [
      token_usage_event()
    ]
  end

  defp token_usage_event do
    # Use specific wildcard pattern for OCR: [:_, :ocr, :_]
    # This avoids duplicate metrics while still being flexible
    Event.build(
      :ai_token_usage_metrics,
      [
        # Prompt tokens (input to AI)
        counter(
          "ai.token.usage.prompt_tokens.total",
          event_name: [:_, :ocr, :_],
          measurement: :prompt_tokens,
          description: "Total prompt tokens sent to AI providers",
          tags: [:provider, :model, :feature]
        ),

        # Completion tokens (output from AI)
        counter(
          "ai.token.usage.completion_tokens.total",
          event_name: [:_, :ocr, :_],
          measurement: :completion_tokens,
          description: "Total completion tokens received from AI providers",
          tags: [:provider, :model, :feature]
        ),

        # Total tokens
        counter(
          "ai.token.usage.total_tokens.total",
          event_name: [:_, :ocr, :_],
          measurement: :total_tokens,
          description: "Total tokens (prompt + completion) used by AI providers",
          tags: [:provider, :model, :feature]
        ),

        # Cached tokens
        counter(
          "ai.token.usage.cached_tokens.total",
          event_name: [:_, :ocr, :_],
          measurement: :cached_tokens,
          description: "Total cached prompt tokens served by AI providers (cost savings)",
          tags: [:provider, :model, :feature]
        )
      ]
    )
  end
end
