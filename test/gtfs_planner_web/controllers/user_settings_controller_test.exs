defmodule GtfsPlannerWeb.UserSettingsControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  @invalid_link_error "Email change link is invalid or it has expired."

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "GET /users/settings/confirm_email/:token" do
    setup %{user: user} do
      new_email = unique_user_email()
      token = change_email_token(user, new_email)
      %{token: token, new_email: new_email}
    end

    test "updates the current user's email exactly once", %{
      conn: conn,
      user: user,
      token: token,
      new_email: new_email
    } do
      conn = get(conn, ~p"/users/settings/confirm_email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(new_email)
      assert Repo.all(UserToken.user_and_contexts_query(user, ["change:#{user.email}"])) == []

      # Reusing the consumed token shares the generic failure without mutation.
      conn = get(conn, ~p"/users/settings/confirm_email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @invalid_link_error
      assert Accounts.get_user_by_email(new_email)
    end

    test "does not update the email with an invalid token", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/settings/confirm_email/oops")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @invalid_link_error
      assert Accounts.get_user_by_email(user.email)
    end

    test "does not update the email with another user's token", %{conn: conn, user: user} do
      other_user = user_fixture()
      other_new_email = unique_user_email()
      other_token = change_email_token(other_user, other_new_email)

      conn = get(conn, ~p"/users/settings/confirm_email/#{other_token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @invalid_link_error
      assert Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(other_user.email)
      refute Accounts.get_user_by_email(other_new_email)
    end

    test "does not update the email with an expired token", %{
      conn: conn,
      user: user,
      token: token,
      new_email: new_email
    } do
      {1, nil} =
        Repo.update_all(UserToken.user_and_contexts_query(user, ["change:#{user.email}"]),
          set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]]
        )

      conn = get(conn, ~p"/users/settings/confirm_email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @invalid_link_error
      assert Accounts.get_user_by_email(user.email)
      refute Accounts.get_user_by_email(new_email)
    end

    test "stores the full return path and keeps the token when logged out", %{
      user: user,
      token: token,
      new_email: new_email
    } do
      conn = get(build_conn(), ~p"/users/settings/confirm_email/#{token}")

      assert redirected_to(conn) == ~p"/users/log_in"
      assert get_session(conn, :user_return_to) == "/users/settings/confirm_email/#{token}"
      assert Accounts.get_user_by_email(user.email)
      refute Accounts.get_user_by_email(new_email)

      # The token was not consumed before login and still works afterwards.
      conn = build_conn() |> log_in_user(user) |> get(~p"/users/settings/confirm_email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Email changed successfully."
      assert Accounts.get_user_by_email(new_email)
    end
  end

  # Builds a change-email token exactly as the settings LiveView will:
  # context "change:<persisted old email>" sent to the proposed address.
  defp change_email_token(user, new_email) do
    {:ok, _} =
      Accounts.deliver_user_update_email_instructions(
        %{user | email: new_email},
        user.email,
        &"http://localhost:4000/users/settings/confirm_email/#{&1}"
      )

    assert_receive {:email, email}
    assert email.to == [{"", new_email}]
    [_, token] = Regex.run(~r{/users/settings/confirm_email/([^"\s]+)}, email.html_body)
    token
  end
end
