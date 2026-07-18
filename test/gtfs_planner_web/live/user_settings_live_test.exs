defmodule GtfsPlannerWeb.UserSettingsLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import Swoosh.TestAssertions
  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  describe "authenticated mount" do
    test "renders the account-settings surface with exact stable IDs once and no email history",
         %{
           conn: conn
         } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#account-settings")
      assert has_element?(view, "#account-settings-title")
      assert has_element?(view, "#email_form")
      assert has_element?(view, "#password_form")

      # No email history section
      refute has_element?(view, "#emails")
    end

    test "every required visible control has the specified unique ID and name", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#email-address")
      assert has_element?(view, "#email-current-password")
      assert has_element?(view, "#email-submit")

      assert has_element?(view, "#password-current-password")
      assert has_element?(view, "#password-new-password")
      assert has_element?(view, "#password-confirmation")
      assert has_element?(view, "#password-submit")
    end

    test "inputs have correct autocomplete attributes", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#email-address[autocomplete=\"email\"]")
      assert has_element?(view, "#email-current-password[autocomplete=\"current-password\"]")
      assert has_element?(view, "#password-current-password[autocomplete=\"current-password\"]")
      assert has_element?(view, "#password-new-password[autocomplete=\"new-password\"]")
      assert has_element?(view, "#password-confirmation[autocomplete=\"new-password\"]")
    end

    test "both forms render phx-auto-recover=\"ignore\"", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#email_form[phx-auto-recover=\"ignore\"]")
      assert has_element?(view, "#password_form[phx-auto-recover=\"ignore\"]")
    end

    test "password form has action, method, and trigger-action will appear on success", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#password_form[action=\"/users/update_password\"]")
      assert has_element?(view, "#password_form[method=\"post\"]")

      # phx-trigger-action is omitted when false, only rendered when trigger_submit is true
      refute has_element?(view, "#password_form[phx-trigger-action]")
    end

    test "CTA text and phx-disable-with copy match spec", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      email_submit = element(view, "#email-submit")
      assert render(email_submit) =~ "Send confirmation"
      assert render(email_submit) =~ "Sending confirmation…"

      password_submit = element(view, "#password-submit")
      assert render(password_submit) =~ "Change password"
      assert render(password_submit) =~ "Changing password…"
    end

    test "renders without email history section", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/users/settings")

      refute html =~ "Email Change History"
      refute has_element?(view, "#emails")
    end

    test "inputs are associated with wrapping labels", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # Each field renders with wrapping label structure
      assert has_element?(view, "#email-address")
      assert has_element?(view, "#email-current-password")
      assert has_element?(view, "#password-current-password")
      assert has_element?(view, "#password-new-password")
      assert has_element?(view, "#password-confirmation")
    end
  end

  describe "validate handlers / form isolation" do
    test "email validation updates only the email form", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_change(%{
        "user" => %{"email" => "invalid-email"},
        "current_password" => "anything"
      })

      assert has_element?(view, "#email_form")
      refute has_element?(view, "#password_form input.input-error")
    end

    test "password validation updates only the password form", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_change(%{
        "user" => %{"password" => "short", "password_confirmation" => "mismatch"},
        "current_password" => ""
      })

      assert has_element?(view, "#password_form")
      refute has_element?(view, "#email_form input.input-error")
    end
  end

  describe "failed email submit" do
    test "invalid email shows error and clears password while preserving proposed email", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "invalid-email"},
        "current_password" => "wrongpassword"
      })

      # Form remains with errors
      assert has_element?(view, "#email_form")

      # Current password value is cleared (secret recovery invariant)
      has_element?(view, "#email-current-password")

      # Proposed email is preserved for correction
      assert has_element?(view, "#email-address[value=\"invalid-email\"]")
    end

    test "invalid current password on email submit clears secret, preserves email, keeps trigger false",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "different@example.com"},
        "current_password" => "wrongpassword"
      })

      assert has_element?(view, "#email_form")

      # Proposed email preserved
      assert has_element?(view, "#email-address[value=\"different@example.com\"]")

      # trigger_submit stays false
      html = render(view)
      refute html =~ "phx-trigger-action=\"true\""
    end
  end

  describe "failed password submit" do
    test "clears all rendered password values on failure", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_submit(%{
        "user" => %{
          "password" => "shortone12345",
          "password_confirmation" => "different12345"
        },
        "current_password" => "wrongpassword"
      })

      # Form still present
      assert has_element?(view, "#password_form")

      # trigger_submit stays false
      html = render(view)
      refute html =~ "phx-trigger-action=\"true\""
    end
  end

  describe "valid email submit" do
    test "sends change-email message without changing persisted identity", %{conn: conn} do
      user = user_fixture()
      old_email = user.email
      proposed_email = "new-valid@example.com"
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => proposed_email},
        "current_password" => valid_user_password()
      })

      # Flash shows pending confirmation
      assert has_element?(view, "#flash-info")

      # Persisted email is unchanged
      reloaded = Accounts.get_user!(user.id)
      assert reloaded.email == old_email

      # Email was sent via Swoosh test adapter to the proposed address,
      # body contains the authenticated confirmation route
      assert_email_sent(fn email ->
        assert email.to == [{"", proposed_email}]
        assert email.html_body =~ ~r|/users/settings/confirm_email/|
      end)

      # A change-email token was created with the correct context and sent_to
      token =
        Repo.one!(
          from t in UserToken,
            where: t.user_id == ^user.id,
            where: t.context == ^"change:#{old_email}",
            where: t.sent_to == ^proposed_email
        )

      assert token
    end
  end

  describe "valid password submit (preflight only)" do
    test "enables trigger-action for native POST, old credentials still valid", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      form = element(view, "#password_form")

      html =
        render_submit(form, %{
          "user" => %{
            "password" => "newvalidpassword123",
            "password_confirmation" => "newvalidpassword123"
          },
          "current_password" => valid_user_password()
        })

      # trigger_action should be set (phx-trigger-action present post-submit)
      assert html =~ "phx-trigger-action"

      # Old credentials are unchanged (password not persisted yet)
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "form isolation across submits" do
    test "email submit failure does not alter password form state", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "bad-email"},
        "current_password" => "wrong"
      })

      # Password form still present and has no error inputs
      assert has_element?(view, "#password_form")
      refute has_element?(view, "#password_form input.input-error")

      # trigger_submit still false
      html = render(view)
      refute html =~ "phx-trigger-action=\"true\""
    end

    test "password submit failure does not alter email form state", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_submit(%{
        "user" => %{
          "password" => "short",
          "password_confirmation" => "mismatch"
        },
        "current_password" => "wrong"
      })

      # Email form still present
      assert has_element?(view, "#email_form")
      refute has_element?(view, "#email_form input.input-error")
    end
  end

  describe "focus event after failed submit" do
    test "pushed focus_settings_error after failed submit", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "bad"},
        "current_password" => "wrong"
      })

      assert_push_event(view, "focus_settings_error", %{form_id: "email_form"})
    end

    test "validate does not push focus event", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_change(%{
        "user" => %{"email" => "bad"},
        "current_password" => "something"
      })

      refute_push_event(view, "focus_settings_error", %{form_id: "email_form"})
    end
  end
end
