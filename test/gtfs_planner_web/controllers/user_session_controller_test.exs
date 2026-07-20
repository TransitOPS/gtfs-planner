defmodule GtfsPlannerWeb.UserSessionControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo

  @new_password "brand new password 123456"
  @failure_flash "Password change failed. Please try again."

  describe "POST /users/log_in" do
    test "logs a member in and installs the digest-derived session topic" do
      %{user: user, organization: organization} = member_user()

      conn = log_in_through_pipeline(user)

      assert redirected_to(conn) == ~p"/"
      token = get_session(conn, :user_token)
      assert Accounts.get_user_by_session_token(token).id == user.id
      assert get_session(conn, :live_socket_id) == session_topic(token)
      assert get_session(conn, :organization_id) == organization.id
    end

    test "logs an administrator in and redirects to organization management" do
      user = user_fixture()
      organization = OrganizationsFixtures.organization_fixture()

      {:ok, _} =
        Organizations.add_user_to_organization(user.id, organization.id, ["administrator"])

      conn = log_in_through_pipeline(user)

      assert redirected_to(conn) == "/admin/organizations"
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token)).id == user.id
    end

    test "writes the remember-me cookie when requested" do
      %{user: user} = member_user()

      conn = log_in_through_pipeline(user, %{"remember_me" => "true"})

      assert redirected_to(conn) == ~p"/"
      assert conn.resp_cookies["user_remember_me"][:value] == get_session(conn, :user_token)
    end

    test "rejects invalid credentials with the bounded recovery code and no session" do
      %{user: user} = member_user()

      conn =
        post(build_conn(), ~p"/users/log_in", %{
          "user" => %{"email" => user.email, "password" => "totally wrong password"}
        })

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "invalid_credentials"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
      assert Enum.sort(Map.keys(conn.assigns.flash)) == ["email", "login_recovery"]
      assert get_session(conn, :user_token) == nil
    end

    test "an unknown email and a wrong password produce the identical recovery state" do
      %{user: user} = member_user()

      wrong_password_conn =
        post(build_conn(), ~p"/users/log_in", %{
          "user" => %{"email" => user.email, "password" => "totally wrong password"}
        })

      unknown_email_conn =
        post(build_conn(), ~p"/users/log_in", %{
          "user" => %{
            "email" => "absent-#{System.unique_integer([:positive])}@example.com",
            "password" => "totally wrong password"
          }
        })

      for conn <- [wrong_password_conn, unknown_email_conn] do
        assert redirected_to(conn) == ~p"/users/log_in"
        assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "invalid_credentials"
        assert Enum.sort(Map.keys(conn.assigns.flash)) == ["email", "login_recovery"]
        assert get_session(conn, :user_token) == nil
      end

      assert Repo.all(UserToken.user_and_contexts_query(user, :all)) == []
    end

    test "bounds the recovered email to 160 characters" do
      long_email = String.duplicate("a", 150) <> "@example.com"

      conn =
        post(build_conn(), ~p"/users/log_in", %{
          "user" => %{"email" => long_email, "password" => "any password value"}
        })

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "invalid_credentials"

      recovered_email = Phoenix.Flash.get(conn.assigns.flash, :email)
      assert String.length(recovered_email) == 160
      assert recovered_email == String.slice(long_email, 0, 160)
    end

    test "rejects a user without organization membership and issues no token" do
      user = user_fixture()

      conn = log_in_through_pipeline(user)

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "organization_required"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
      assert Enum.sort(Map.keys(conn.assigns.flash)) == ["email", "login_recovery"]
      assert get_session(conn, :user_token) == nil
      assert Repo.all(UserToken.user_and_contexts_query(user, :all)) == []
    end

    test "rejects a deactivated member and issues no token" do
      %{user: user, organization: organization} = member_user()
      {:ok, _} = Organizations.deactivate_user_in_organization(user.id, organization.id)

      conn = log_in_through_pipeline(user)

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "deactivated"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
      assert Enum.sort(Map.keys(conn.assigns.flash)) == ["email", "login_recovery"]
      assert get_session(conn, :user_token) == nil
      assert Repo.all(UserToken.user_and_contexts_query(user, :all)) == []
    end
  end

  describe "POST /users/update_password" do
    test "commits, disconnects old sessions, clears remember-me, and issues a fresh session" do
      %{user: user, organization: organization} = member_user()

      conn = log_in_through_pipeline(user, %{"remember_me" => "true"})
      assert conn.resp_cookies["user_remember_me"][:value]

      old_token = get_session(conn, :user_token)
      old_topic = get_session(conn, :live_socket_id)

      other_token = Accounts.generate_user_session_token(user)
      other_topic = session_topic(other_token)

      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, old_topic)
      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, other_topic)

      conn = post(conn, ~p"/users/update_password", valid_update_params())

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Password updated successfully."

      new_token = get_session(conn, :user_token)
      assert is_binary(new_token)
      assert new_token != old_token
      assert Accounts.get_user_by_session_token(new_token).id == user.id
      assert get_session(conn, :live_socket_id) == session_topic(new_token)
      assert get_session(conn, :organization_id) == organization.id

      assert Accounts.get_user_by_session_token(old_token) == nil
      assert Accounts.get_user_by_session_token(other_token) == nil

      assert_receive %Phoenix.Socket.Broadcast{topic: ^old_topic, event: "disconnect"}
      assert_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}
      refute_receive %Phoenix.Socket.Broadcast{}

      remember_cookie = conn.resp_cookies["user_remember_me"]
      assert remember_cookie.max_age == 0
      refute Map.has_key?(remember_cookie, :value)

      assert Accounts.get_user_by_email_and_password(user.email, @new_password)
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password()) == nil
    end

    test "success without a prior remember-me cookie issues no replacement cookie" do
      %{user: user} = member_user()

      conn = log_in_through_pipeline(user)
      refute conn.resp_cookies["user_remember_me"]

      conn = post(conn, ~p"/users/update_password", valid_update_params())

      assert redirected_to(conn) == ~p"/users/settings"
      remember_cookie = conn.resp_cookies["user_remember_me"]
      assert remember_cookie.max_age == 0
      refute Map.has_key?(remember_cookie, :value)
    end

    test "an invalid current password mutates nothing and keeps the current session" do
      %{user: user} = member_user()

      conn = log_in_through_pipeline(user)
      old_token = get_session(conn, :user_token)
      old_topic = get_session(conn, :live_socket_id)
      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, old_topic)

      conn =
        post(conn, ~p"/users/update_password", %{
          "current_password" => "wrong current password",
          "user" => %{
            "password" => @new_password,
            "password_confirmation" => @new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @failure_flash
      assert get_session(conn, :user_token) == old_token
      assert Accounts.get_user_by_session_token(old_token).id == user.id
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      assert Accounts.get_user_by_email_and_password(user.email, @new_password) == nil
      refute conn.resp_cookies["user_remember_me"]
      refute_receive %Phoenix.Socket.Broadcast{}
    end

    test "an invalid new password mutates nothing" do
      %{user: user} = member_user()

      conn = log_in_through_pipeline(user)
      old_token = get_session(conn, :user_token)

      conn =
        post(conn, ~p"/users/update_password", %{
          "current_password" => valid_user_password(),
          "user" => %{
            "password" => @new_password,
            "password_confirmation" => "does not match the new password"
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @failure_flash
      assert get_session(conn, :user_token) == old_token
      assert Accounts.get_user_by_session_token(old_token).id == user.id
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "malformed payloads are rejected without mutation" do
      %{user: user} = member_user()

      conn = log_in_through_pipeline(user)
      old_token = get_session(conn, :user_token)

      malformed_payloads = [
        %{},
        %{"current_password" => valid_user_password()},
        %{"user" => %{"password" => @new_password, "password_confirmation" => @new_password}},
        %{"current_password" => valid_user_password(), "user" => %{"password" => @new_password}}
      ]

      for params <- malformed_payloads do
        rejected = post(conn, ~p"/users/update_password", params)
        assert redirected_to(rejected) == ~p"/users/settings"
        assert Phoenix.Flash.get(rejected.assigns.flash, :error) == @failure_flash
      end

      assert Accounts.get_user_by_session_token(old_token).id == user.id
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      assert Accounts.get_user_by_email_and_password(user.email, @new_password) == nil
    end

    test "post-commit membership failure stays logged out with no replacement session" do
      user = user_fixture()
      conn = build_conn() |> log_in_user(user)
      old_token = Plug.Conn.get_session(conn, :user_token)

      conn = post(conn, ~p"/users/update_password", valid_update_params())

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "organization_required"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
      assert Enum.sort(Map.keys(conn.assigns.flash)) == ["email", "login_recovery"]
      assert conn.resp_cookies["user_remember_me"].max_age == 0

      # The password committed and every prior token is invalid; none was reissued.
      assert Accounts.get_user_by_email_and_password(user.email, @new_password)
      assert Accounts.get_user_by_session_token(old_token) == nil
      assert Repo.all(UserToken.user_and_contexts_query(user, :all)) == []

      # The retained request session can no longer authenticate.
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "post-commit deactivation failure stays logged out with no replacement session" do
      %{user: user, organization: organization} = member_user()
      {:ok, _} = Organizations.deactivate_user_in_organization(user.id, organization.id)

      # Deactivation deleted prior sessions; install one directly to reach the action.
      conn = build_conn() |> log_in_user(user)

      conn = post(conn, ~p"/users/update_password", valid_update_params())

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :login_recovery) == "deactivated"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == user.email
      assert Enum.sort(Map.keys(conn.assigns.flash)) == ["email", "login_recovery"]
      assert Accounts.get_user_by_email_and_password(user.email, @new_password)
      assert Repo.all(UserToken.user_and_contexts_query(user, :all)) == []
    end

    test "a sequential replay with the invalidated old session cannot mutate again" do
      %{user: user} = member_user()

      conn = log_in_through_pipeline(user)
      old_token = get_session(conn, :user_token)

      conn = post(conn, ~p"/users/update_password", valid_update_params())
      assert redirected_to(conn) == ~p"/users/settings"

      third_password = "yet another password 123456"

      replay_conn =
        build_conn()
        |> init_test_session(%{user_token: old_token})
        |> post(~p"/users/update_password", %{
          "current_password" => @new_password,
          "user" => %{
            "password" => third_password,
            "password_confirmation" => third_password
          }
        })

      assert redirected_to(replay_conn) == ~p"/users/log_in"
      assert Accounts.get_user_by_email_and_password(user.email, @new_password)
      assert Accounts.get_user_by_email_and_password(user.email, third_password) == nil
    end

    test "requires an authenticated user" do
      conn = post(build_conn(), ~p"/users/update_password", %{})

      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == nil
    end
  end

  describe "DELETE /users/log_out" do
    test "logs the user out" do
      %{user: user} = member_user()
      conn = log_in_through_pipeline(user)

      conn = delete(conn, ~p"/users/log_out")

      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_token) == nil
    end
  end

  defp member_user do
    user = user_fixture()
    organization = OrganizationsFixtures.organization_fixture()

    {:ok, _} =
      Organizations.add_user_to_organization(user.id, organization.id, [
        "pathways_studio_editor"
      ])

    %{user: user, organization: organization}
  end

  defp log_in_through_pipeline(user, extra_params \\ %{}) do
    params =
      Map.merge(
        %{"email" => user.email, "password" => valid_user_password()},
        extra_params
      )

    post(build_conn(), ~p"/users/log_in", %{"user" => params})
  end

  defp valid_update_params do
    %{
      "current_password" => valid_user_password(),
      "user" => %{
        "password" => @new_password,
        "password_confirmation" => @new_password
      }
    }
  end

  defp session_topic(encoded_token) do
    {:ok, digest} = UserToken.session_token_digest(encoded_token)
    "users_sessions:" <> Base.url_encode64(digest, padding: false)
  end
end
