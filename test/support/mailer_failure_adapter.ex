defmodule GtfsPlanner.MailerFailureAdapter do
  @moduledoc """
  Swoosh adapter that deterministically fails every delivery.

  Installed by tests that need to exercise the email delivery failure path
  without touching a real transport.
  """

  use Swoosh.Adapter

  def deliver(_email, _config) do
    {:error, :simulated_delivery_failure}
  end
end
