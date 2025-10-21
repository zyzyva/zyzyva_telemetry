defmodule ZyzyvaTelemetry.ErrorTracking do
  @moduledoc """
  Standardized Tower configuration for ecosystem apps.
  Writes structured JSON logs for Loki ingestion.
  """

  def child_spec(opts) do
    service_name = Keyword.fetch!(opts, :service_name)

    reporters = [
      [
        module: ZyzyvaTelemetry.Reporters.StructuredFile,
        service_name: service_name,
        log_path: "/var/log/#{service_name}/errors.json",
        format: :json
      ]
    ]

    %{
      id: Tower,
      start: {Tower, :start_link, [[reporters: reporters]]},
      type: :supervisor
    }
  end
end