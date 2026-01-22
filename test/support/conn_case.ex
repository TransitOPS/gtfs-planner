defmodule GtfsPlannerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GtfsPlannerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint GtfsPlannerWeb.Endpoint

      use GtfsPlannerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import GtfsPlannerWeb.ConnCase
    end
  end

  setup tags do
    GtfsPlanner.DataCase.setup_sandbox(tags)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_private(:phoenix_endpoint, GtfsPlannerWeb.Endpoint)

    {:ok, conn: conn}
  end

  @doc """
  Logs in the given user by generating a session token and setting up the connection.
  This is a test helper that should be used in tests that require an authenticated user.

  ## Examples

      user = user_fixture()
      conn = log_in_user(conn, user)
      
      # With organization context
      conn = log_in_user(conn, user, organization: organization)

  ## Options
    * `:organization` - Optional organization to set in the session. Required for LiveViews
      that use the `AssignOrganization` on_mount hook.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = GtfsPlanner.Accounts.generate_user_session_token(user)
    organization = Keyword.get(opts, :organization)

    session = %{user_token: token}

    session =
      if organization, do: Map.put(session, :organization_id, organization.id), else: session

    conn
    |> Phoenix.ConnTest.init_test_session(session)
    |> Plug.Conn.assign(:current_user, user)
  end
end
