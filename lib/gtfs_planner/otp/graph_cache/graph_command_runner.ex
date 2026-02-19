defmodule GtfsPlanner.Otp.GraphCommandRunner do
  @moduledoc """
  Behaviour contract for executing OTP graph build commands.

  This abstraction keeps graph build orchestration testable by allowing
  command execution to be mocked in unit tests.
  """

  @type run_options :: [
          {:env, [{String.t(), String.t()}]}
          | {:cd, String.t()}
          | {:stderr_to_stdout, boolean()}
          | {:timeout, timeout()}
          | {:into, Collectable.t()}
          | {:arg0, String.t()}
        ]

  @callback run(command :: String.t(), args :: [String.t()], options :: run_options()) ::
              {output :: String.t(), exit_status :: non_neg_integer()}
end
