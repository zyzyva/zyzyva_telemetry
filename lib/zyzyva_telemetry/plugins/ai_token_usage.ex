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
        enabled: true,                   # Enabled by default
        track_by_model: true,            # Track metrics per AI model
        track_cached_tokens: true        # Track prompt caching separately

  ## Telemetry Events

  **IMPORTANT**: Your application must emit events using the exact event name
  `[:zyzyva, :ai, :token_usage]`. This is the library-namespaced event that
  the plugin listens to.

  **NOTE**: Telemetry.Metrics does NOT support wildcard patterns in event names.
  Patterns like `[:_, :ai, :_]` or `[:your_app, :*, :token_usage]` will not work.
  You must use the exact event name `[:zyzyva, :ai, :token_usage]`.

      :telemetry.execute(
        [:zyzyva, :ai, :token_usage],   # Must use exact event name - wildcards don't work
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

  - `ai_token_usage_prompt_tokens_total` - Total input tokens sent to AI
  - `ai_token_usage_completion_tokens_total` - Total output tokens from AI
  - `ai_token_usage_total_tokens_total` - Combined token usage
  - `ai_token_usage_cached_tokens_total` - Cached tokens (cost savings)

  All metrics tagged with:
  - `provider` - AI provider (OpenAI, Mistral, Anthropic, etc.)
  - `model` - AI model name
  - `feature` - Application feature using AI

  **NOTE**: Metric names in Prometheus use underscores (e.g. `ai_token_usage_prompt_tokens_total`),
  not dots. The dots in metric definitions get converted to underscores by the Prometheus reporter.

  ## Example Usage

  ### Business Card OCR

      # In your OCR handler
      :telemetry.execute(
        [:zyzyva, :ai, :token_usage],
        %{
          prompt_tokens: usage["prompt_tokens"],
          completion_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"],
          cached_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
        },
        %{provider: "OpenAI", model: "gpt-4o", feature: "business_card_scanner"}
      )

  ### Chat Completion

      :telemetry.execute(
        [:zyzyva, :ai, :token_usage],
        %{
          prompt_tokens: 150,
          completion_tokens: 75,
          total_tokens: 225,
          cached_tokens: 50
        },
        %{provider: "Anthropic", model: "claude-3-5-sonnet", feature: "chat"}
      )

  ## Troubleshooting

  If metrics aren't appearing in Prometheus:

  1. **Check event name**: Must be exactly `[:zyzyva, :ai, :token_usage]`.
     App-specific event names like `[:my_app, :ocr, :token_usage]` won't work.

  2. **No wildcards**: Event names like `[:_, :ai, :_]` don't work in Telemetry.Metrics.
     Wildcards only work with `:telemetry.attach/4`, not metric definitions.

  3. **Check configuration**: Plugin is enabled by default. If you set `enabled: false`,
     no metrics will be collected.

  4. **Verify telemetry execution**: Add logging to confirm events are being emitted:
     ```
     result = :telemetry.execute([:zyzyva, :ai, :token_usage], measurements, metadata)
     Logger.info("Telemetry event emitted: \#{inspect(result)}")
     ```

  5. **Check metric names**: In Prometheus, metric names use underscores, not dots.
     Look for `ai_token_usage_prompt_tokens_total`, not `ai.token.usage.prompt_tokens.total`.

  6. **Tags must be atoms**: The `tags` parameter in counter definitions must be a list
     of atoms like `[:provider, :model]`, not a custom function.
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
    # Listen to library-namespaced event that applications should emit
    Event.build(
      :ai_token_usage_metrics,
      [
        # Prompt tokens (input to AI)
        counter(
          "ai.token.usage.prompt_tokens.total",
          event_name: [:zyzyva, :ai, :token_usage],
          measurement: :prompt_tokens,
          description: "Total prompt tokens sent to AI providers",
          tags: [:provider, :model, :feature]
        ),

        # Completion tokens (output from AI)
        counter(
          "ai.token.usage.completion_tokens.total",
          event_name: [:zyzyva, :ai, :token_usage],
          measurement: :completion_tokens,
          description: "Total completion tokens received from AI providers",
          tags: [:provider, :model, :feature]
        ),

        # Total tokens
        counter(
          "ai.token.usage.total_tokens.total",
          event_name: [:zyzyva, :ai, :token_usage],
          measurement: :total_tokens,
          description: "Total tokens (prompt + completion) used by AI providers",
          tags: [:provider, :model, :feature]
        ),

        # Cached tokens
        counter(
          "ai.token.usage.cached_tokens.total",
          event_name: [:zyzyva, :ai, :token_usage],
          measurement: :cached_tokens,
          description: "Total cached prompt tokens served by AI providers (cost savings)",
          tags: [:provider, :model, :feature]
        )
      ]
    )
  end
end
