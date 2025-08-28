defmodule Mix.Tasks.Zyzyva.TestEvents do
  @moduledoc """
  Generates test monitoring events for QA purposes.

  ## Usage

      mix zyzyva.test_events [options]

  ## Options

    * `--count N` - Number of events to generate (default: 10)
    * `--service NAME` - Service name to use (default: app name)
    * `--critical` - Include critical events
    * `--incident` - Generate a critical incident scenario
    * `--performance N` - Run performance degradation test for N seconds

  ## Examples

      # Generate 10 normal test events
      mix zyzyva.test_events
      
      # Generate 50 events including critical ones
      mix zyzyva.test_events --count 50 --critical
      
      # Generate a critical incident
      mix zyzyva.test_events --incident
      
      # Run a 60-second performance degradation test
      mix zyzyva.test_events --performance 60
  """

  use Mix.Task
  alias ZyzyvaTelemetry.TestGenerator

  @shortdoc "Generates test monitoring events"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          count: :integer,
          service: :string,
          critical: :boolean,
          incident: :boolean,
          performance: :integer
        ],
        aliases: [
          c: :count,
          s: :service,
          i: :incident,
          p: :performance
        ]
      )

    # Start the application to ensure SqliteWriter is available
    Mix.Task.run("app.start")

    cond do
      opts[:incident] ->
        run_incident_test(opts[:service])

      opts[:performance] ->
        run_performance_test(opts[:performance])

      true ->
        run_standard_test(opts)
    end
  end

  defp run_standard_test(opts) do
    count = opts[:count] || 10

    Mix.shell().info("Generating #{count} test events...")

    {:ok, summary} =
      TestGenerator.generate_test_events(
        count: count,
        service_name: opts[:service],
        include_critical: opts[:critical] || false
      )

    Mix.shell().info("""

    Test events generated successfully!
    - Service: #{summary.service_name}
    - Successful: #{summary.successful}
    - Failed: #{summary.failed}

    The events have been written to the local SQLite database and will be
    picked up by the monitoring aggregator on the next polling cycle.
    """)
  end

  defp run_incident_test(service) do
    Mix.shell().info("🚨 Generating CRITICAL INCIDENT simulation...")

    {:ok, summary} = TestGenerator.generate_critical_incident(service)

    Mix.shell().info("""

    Critical incident simulation complete!
    - Service: #{summary.service_name}
    - Events generated: #{summary.events_generated}
    - Batch ID: #{summary.batch_id}

    Check your monitoring dashboard for alerts!
    """)
  end

  defp run_performance_test(duration) do
    duration = duration || 30

    Mix.shell().info("Starting #{duration}-second performance degradation test...")

    {:ok, info} = TestGenerator.generate_performance_degradation(duration)

    Mix.shell().info("""

    Performance test started!
    - Duration: #{info.duration} seconds
    - Service: #{info.service}

    The test is running in the background. Check your monitoring dashboard
    to see the degradation pattern emerge.
    """)

    # Keep the process alive for the duration
    Process.sleep(duration * 1000)
    Mix.shell().info("Performance test completed!")
  end
end
