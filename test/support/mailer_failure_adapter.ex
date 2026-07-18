defmodule GtfsPlanner.MailerFailureAdapter do
  use Swoosh.Adapter

  def deliver(_email, _config) do
    {:error, :simulated_delivery_failure}
  end
end
