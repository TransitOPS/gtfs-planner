defmodule GtfsPlannerWeb.SessionRevocationsTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Organizations
  alias GtfsPlannerWeb.Endpoint
  alias GtfsPlannerWeb.SessionRevocations

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
    target = editor_fixture(organization)

    # The application supervisor owns this process; no test copy is started.
    assert is_pid(Process.whereis(SessionRevocations))

    %{organization: organization, admin: admin, target: target}
  end

  test "deactivation disconnects the revoked browser session", context do
    web_token = Accounts.generate_user_session_token(context.target)
    api_token = Accounts.generate_api_session_token(context.target)
    web_topic = session_topic(web_token)
    api_topic = session_topic(api_token)
    :ok = Endpoint.subscribe(web_topic)
    :ok = Endpoint.subscribe(api_topic)

    assert {:ok, %{deactivated_at: %DateTime{}}} =
             Organizations.deactivate_user_in_organization(
               context.admin,
               context.target.id,
               context.organization.id
             )

    refute Accounts.get_user_by_session_token(web_token)
    refute Accounts.get_user_by_api_session_token(api_token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^web_topic, event: "disconnect", payload: %{}}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^api_topic}
  end

  test "role changes disconnect the revoked browser session", context do
    web_token = Accounts.generate_user_session_token(context.target)
    web_topic = session_topic(web_token)
    :ok = Endpoint.subscribe(web_topic)

    assert {:ok, %{roles: []}} =
             Organizations.update_user_roles(
               context.admin,
               context.target.id,
               context.organization.id,
               []
             )

    refute Accounts.get_user_by_session_token(web_token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^web_topic, event: "disconnect", payload: %{}}
  end

  test "the application subscriber ignores unrelated messages" do
    send(SessionRevocations, :unrelated)
    assert :sys.get_state(SessionRevocations) == %{}
  end

  defp session_topic(encoded_token) do
    {:ok, digest} = UserToken.session_token_digest(encoded_token)
    "users_sessions:" <> Base.url_encode64(digest, padding: false)
  end
end
