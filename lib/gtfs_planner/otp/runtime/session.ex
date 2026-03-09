defmodule GtfsPlanner.Otp.Runtime.Session do
  @moduledoc """
  Runtime session metadata for a single OTP server lifecycle.
  """

  @enforce_keys [
    :command,
    :args,
    :host,
    :port,
    :base_url,
    :graphql_url,
    :graph_workspace_dir,
    :process,
    :runtime_log_path
  ]
  defstruct [
    :command,
    :args,
    :host,
    :port,
    :base_url,
    :graphql_url,
    :graph_workspace_dir,
    :process,
    :runtime_log_path
  ]

  @type process_handle :: pid() | port() | reference() | term()

  @type t :: %__MODULE__{
          command: String.t(),
          args: [String.t()],
          host: String.t(),
          port: pos_integer(),
          base_url: String.t(),
          graphql_url: String.t(),
          graph_workspace_dir: String.t(),
          process: process_handle(),
          runtime_log_path: String.t()
        }
end
