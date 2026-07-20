defmodule GtfsPlanner.Organizations.AdminReadAdapter do
  @moduledoc """
  Operational read contract for the administration screens.

  Administration reads must distinguish three outcomes so the LiveViews can offer
  the right recovery: a ready value, a missing record, and a database connection
  that is temporarily unavailable. Only a lost database connection is normalized;
  query, cast, configuration, and programmer defects stay crash-visible so a code
  defect is never presented to an operator as downtime.

  `GtfsPlanner.Organizations.AdminReadAdapter.Repo` is the production
  implementation. `GtfsPlanner.Organizations` resolves the module at call time
  from `:gtfs_planner, :organizations_admin_read_adapter`, defaulting to the Repo
  adapter, so focused LiveView tests can substitute this application-owned
  behaviour without mocking `Repo` or Postgrex.
  """

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Organizations.Organization

  @typedoc """
  One organization member, in the same shape as
  `GtfsPlanner.Organizations.list_users_in_organization/1`.
  """
  @type member :: %{
          user: User.t(),
          roles: [String.t()],
          deactivated_at: DateTime.t() | nil
        }

  @callback list_organizations() ::
              {:ok, [Organization.t()]} | {:error, :unavailable}

  @callback fetch_organization(Ecto.UUID.t()) ::
              {:ok, Organization.t()} | {:error, :not_found | :unavailable}

  @callback list_users(Ecto.UUID.t()) ::
              {:ok, [member()]} | {:error, :unavailable}
end
