defmodule GtfsPlannerWeb.UserSettingsLiveFailureTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import Swoosh.TestAssertions

  alias GtfsPlanner.Accounts

  setup do
    old_config = Application.get_env(:gtfs_planner, GtfsPlanner.Mailer)

    on_exit(fn ->
      Application.put_env(:gtfs_planner, GtfsPlanner.Mailer, old_config)
    end)

    %{old_config: old_config}
  end

  describe "email delivery failure" do
    test "reports retry feedback, preserves proposed email, clears password, leaves identity unchanged",
         %{conn: conn} do
      Application.put_env(
        :gtfs_planner,
        GtfsPlanner.Mailer,
        adapter: GtfsPlanner.MailerFailureAdapter
      )

      user = user_fixture()
      old_email = user.email
      proposed_email = "new-failure@example.com"
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => proposed_email},
        "current_password" => valid_user_password()
      })

      # No success flash
      refute has_element?(view, "#flash-info")

      # Error/retry flash is present with retry guidance
      assert has_element?(view, "#flash-error", "We couldn't send the confirmation email")

      # Persisted email unchanged
      reloaded = Accounts.get_user!(user.id)
      assert reloaded.email == old_email

      # Proposed email is preserved in the form
      assert has_element?(view, "#email-address[value=\"#{proposed_email}\"]")

      # Password is cleared (empty value, no secret rendered)
      assert has_element?(view, "#email-current-password[value=\"\"]")

      # trigger_submit stays false
      html = render(view)
      refute html =~ "phx-trigger-action=\"true\""
    end

    test "failure adapter returns correct error tuple" do
      assert {:error, :simulated_delivery_failure} ==
               GtfsPlanner.MailerFailureAdapter.deliver(nil, nil)
    end

    test "test adapter operational after restore from prior failure test", %{conn: conn} do
      user = user_fixture()
      old_email = user.email
      proposed_email = "after-restore@example.com"
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => proposed_email},
        "current_password" => valid_user_password()
      })

      assert has_element?(view, "#flash-info")
      reloaded = Accounts.get_user!(user.id)
      assert reloaded.email == old_email

      assert_email_sent(to: [{"", proposed_email}])
    end
  end
end
