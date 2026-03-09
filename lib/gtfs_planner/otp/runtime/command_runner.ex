defmodule GtfsPlanner.Otp.Runtime.CommandRunner do
  @moduledoc """
  Behaviour for starting and stopping the OTP runtime process.
  """

  alias GtfsPlanner.Otp.Runtime.Session

  @type start_opts :: keyword()
  @type stop_opts :: keyword()

  @callback start(String.t(), [String.t()], start_opts()) ::
              {:ok, Session.process_handle()} | {:error, term()}

  @callback stop(Session.process_handle(), stop_opts()) :: :ok | {:error, term()}
end
