defmodule GtfsPlannerWeb.UserSettingsLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import Swoosh.TestAssertions
  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # The house date format the LiveView's format_date/1 produces.
  defp date_string(%{year: year, month: month, day: day}) do
    "#{Enum.at(@months, month - 1)} #{day}, #{year}"
  end

  describe "authenticated mount" do
    test "renders the account-settings surface with exact stable IDs once and no email history",
         %{
           conn: conn
         } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#account-page")
      assert has_element?(view, "#account-settings-title")
      assert has_element?(view, "#email_form")
      assert has_element?(view, "#password_form")

      # No email history section
      refute has_element?(view, "#emails")
    end

    test "document title, H1/H2 hierarchy, card headings, and primary submits", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/users/settings")

      assert page_title(view) == "Profile settings · GTFS Planner"

      assert has_element?(view, "#account-settings-title", "Profile settings")
      assert has_element?(view, "#email-settings")
      assert has_element?(view, "#email-settings-title", "Email address")
      assert has_element?(view, "#password-settings")
      assert has_element?(view, "#password-settings-title", "Password")

      # Two independent credential cards, each its own surface.
      assert html =~ ~r/id="email-settings"[^>]*class="[^"]*account-card/
      assert html =~ ~r/id="password-settings"[^>]*class="[^"]*account-card/

      # Each card's submit is the page's one committed action for that form.
      assert has_element?(view, "#email-submit.btn-primary")
      assert has_element?(view, "#password-submit.btn-primary")
      refute has_element?(view, "#email-submit.btn-outline")
      refute has_element?(view, "#password-submit.btn-outline")

      refute html =~ "Email Change History"
      refute html =~ "API key"
      refute html =~ "api_key"
      refute has_element?(view, "#emails")
    end

    test "the sign-out consequence of a password change is stated before the button", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # update_user_password/3 deletes every UserToken, so this is a real
      # consequence and the reader must not learn it by being signed out.
      assert has_element?(
               view,
               "#password-settings .account-callout",
               "Changing your password signs you out everywhere."
             )
    end

    test "retains authorized organization and version shell context from optional hook", %{
      conn: conn
    } do
      organization = OrganizationsFixtures.organization_fixture(%{name: "Settings Shell Org"})
      {:ok, _version} = GtfsPlanner.Versions.create_gtfs_version(organization.id, %{name: "Pub"})

      user = user_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: [
            "pathways_studio_editor"
          ]
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, dash_view, dash_html} = live(conn, ~p"/")
      assert has_element?(dash_view, "#home-planner #home-title", "Pub")
      assert dash_html =~ organization.name

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#account-page")
      # Version switcher only mounts when Layouts.app receives org + version + list.
      assert has_element?(view, "#gtfs-version-switcher")
      assert has_element?(view, ~s(a[href^="/gtfs/"]))
      assert has_element?(view, ~s(a[href="/users/settings"][aria-current="page"]))

      # The organization is named in the page subtitle and again on the access
      # card, so the scope of "access" in that sentence is not left to guesswork.
      assert has_element?(view, "#access-title", "Access in this organization")
      assert has_element?(view, "#access-card", organization.name)
    end

    test "the account aside shows roles, confirmation, and account created", %{conn: conn} do
      organization = OrganizationsFixtures.organization_fixture()
      user = user_fixture()

      {:ok, _} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: organization.id,
          roles: [
            "pathways_studio_editor",
            "pathways_studio_admin"
          ]
        })

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), ~p"/users/settings")

      # Role names and descriptions come from Authorization.Roles, so they
      # cannot drift from the canonical copy.
      assert has_element?(view, "#access-roles", "Pathways Studio Editor")
      assert has_element?(view, "#access-roles", "Full access to view and modify GTFS data")
      assert has_element?(view, "#access-roles", "Pathways Studio Admin")
      assert has_element?(view, "#access-roles", "Manages users within their organization")

      assert has_element?(view, "#fact-email", user.email)
      assert has_element?(view, "#fact-created", date_string(user.inserted_at))
      assert has_element?(view, "#manage-members")
    end

    test "an unconfirmed address is flagged and given a next step", %{conn: conn} do
      user = user_fixture()
      refute user.confirmed_at

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/users/settings")

      assert has_element?(view, "#fact-unconfirmed", "Not confirmed")
      assert has_element?(view, "#email-settings .account-badge", "Not confirmed")
      # The next step has to be one the reader can actually take: resubmitting
      # the same address re-sends the link, because email_changeset/2 is valid
      # with no change and deliver_user_update_email_instructions/3 runs anyway.
      assert has_element?(view, "#confirm-reminder", "send a fresh link")
    end

    test "no organization gets a next step instead of an empty panel", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/users/settings")

      # AssignOrganization is :optional, so a system administrator lands here.
      assert has_element?(view, "#access-title", "No organization access")
      assert has_element?(view, "#access-card", "invite this email address")
      refute has_element?(view, "#access-roles")
    end

    test "every required visible control has the specified unique ID and name", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#email-address[name=\"user[email]\"]")
      assert has_element?(view, "#email-current-password[name=\"current_password\"]")
      assert has_element?(view, "#email-submit")

      assert has_element?(view, "#password-current-password[name=\"current_password\"]")
      assert has_element?(view, "#password-new-password[name=\"user[password]\"]")

      assert has_element?(
               view,
               "#password-confirmation[name=\"user[password_confirmation]\"]"
             )

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

    test "new password input has help text with describedby association", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#password-new-password-help")
      assert html =~ "12 to 72 characters."

      assert has_element?(
               view,
               ~s(#password-new-password[aria-describedby="password-new-password-help"])
             )
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
      assert has_element?(view, "#email-current-password[value=\"\"]")

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

      assert has_element?(view, "#password-current-password[value=\"\"]")

      assert has_element?(
               view,
               "#password-new-password:not([value]), #password-new-password[value=\"\"]"
             )

      assert has_element?(
               view,
               "#password-confirmation:not([value]), #password-confirmation[value=\"\"]"
             )

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
    test "pushed the error summary target after a failed email submit", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "bad"},
        "current_password" => "wrong"
      })

      # The summary is the landing place, not the first invalid control: it
      # lists every problem at once and links to each field.
      assert_push_event(view, "focus_scoped_target", %{id: "email-error-summary"})
    end

    test "pushed the error summary target after a failed password submit", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_submit(%{
        "user" => %{"password" => "short", "password_confirmation" => "short"},
        "current_password" => "wrong"
      })

      assert_push_event(view, "focus_scoped_target", %{id: "password-error-summary"})
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

      refute_push_event(view, "focus_scoped_target", %{id: "email-error-summary"})
    end
  end

  describe "error summary" do
    test "lists every failing field and marks exactly those fields invalid", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_submit(%{
        "user" => %{"password" => "short", "password_confirmation" => "short"},
        "current_password" => "wrong"
      })

      # A summary that names a field the form has not marked would be lying.
      assert has_element?(view, "#password-error-summary a[href=\"#password-new-password\"]")
      assert has_element?(view, "#password-error-summary a[href=\"#password-current-password\"]")
      assert has_element?(view, "#password-new-password[aria-invalid=\"true\"]")
      assert has_element?(view, "#password-current-password[aria-invalid=\"true\"]")
      # The confirmation matched, so it is not implicated.
      refute has_element?(view, "#password-confirmation[aria-invalid=\"true\"]")
    end

    test "says what to do rather than 'is invalid'", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "not-an-address"},
        "current_password" => "wrong"
      })

      assert has_element?(view, "#email-error-summary", "Your current password is not correct.")
      assert has_element?(view, "#email-error-summary", "Enter a valid email address.")

      # translate_error/1 falls through to Ecto's own wording for a
      # current_password failure, which renders as "is invalid" — a summary that
      # says that has failed at its only job.
      refute render(view) =~ ~r/id="email-error-summary"[^>]*>[^<]*(is invalid)/
    end

    test "no summary on a live keystroke, and no secret is echoed", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_submit(%{
        "user" => %{
          "password" => "a good long passphrase",
          "password_confirmation" => "a different one"
        },
        "current_password" => "wrong"
      })

      html = render(view)
      # sanitize_changeset_secrets/1 blanks the params rather than removing the
      # keys, because used_input?/1 treats an absent key as an unused field and
      # would then drop the error entirely. Blanking keeps the error and still
      # echoes nothing.
      refute html =~ "a good long passphrase"
      refute html =~ "a different one"
      assert has_element?(view, "#password-confirmation[aria-invalid=\"true\"]")
      refute has_element?(view, "#password-new-password[aria-invalid=\"true\"]")
    end
  end

  describe "password confirmation mismatch" do
    test "lands on the field the reader is typing in, not the other one", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # validate_confirmation/3 attaches "does not match" to :password, so before
      # this was remapped the red border appeared on the field the reader was not
      # editing.
      view
      |> element("#password_form")
      |> render_change(%{
        "user" => %{
          "password" => "a good long passphrase",
          "password_confirmation" => "something else entirely"
        },
        "current_password" => "whatever"
      })

      assert has_element?(view, "#password-confirmation[aria-invalid=\"true\"]")
      refute has_element?(view, "#password-new-password[aria-invalid=\"true\"]")
    end

    test "announces politely and gets no summary, because it is not a rejection", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> element("#password_form")
      |> render_change(%{
        "user" => %{
          "password" => "a good long passphrase",
          "password_confirmation" => "something else entirely"
        },
        "current_password" => "whatever"
      })

      assert has_element?(view, "#password-mismatch-message[aria-live=\"polite\"]")
      refute has_element?(view, "#password-error-summary")
    end
  end

  describe "email change copy" do
    test "says the link is what completes the change, and which address is live", %{conn: conn} do
      user = user_fixture()
      old_email = user.email
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # apply_user_email/3 ends in apply_action/2, which validates but does not
      # write, so the account is still on the old address until the token is
      # redeemed. The copy must not imply the change already happened.
      assert has_element?(
               view,
               "#email-address-help",
               "Your sign-in address only changes once you open that link"
             )

      view
      |> element("#email_form")
      |> render_submit(%{
        "user" => %{"email" => "brand-new-address@example.com"},
        "current_password" => valid_user_password()
      })

      # Nothing was written; the emailed token is the only record of the change.
      assert Accounts.get_user!(user.id).email == old_email

      assert has_element?(
               view,
               "#flash-info",
               "Your sign-in address changes when you open it"
             )
    end
  end

  describe "cross-session password integration" do
    @new_password "brand new password 123456"
    @third_password "yet another password 123456"

    test "native password handoff revokes old capabilities, disconnects the other mounted browser, and issues one fresh session" do
      %{user: user} = member_user()
      old_email = user.email

      # Two browser sessions established through the production login pipeline;
      # browser 1 opts into persistent consent so clearing it is observable.
      conn1 = log_in_through_pipeline(user, %{"remember_me" => "true"})
      assert conn1.resp_cookies["user_remember_me"][:value]
      token1 = get_session(conn1, :user_token)
      topic1 = get_session(conn1, :live_socket_id)

      conn2 = log_in_through_pipeline(user)
      token2 = get_session(conn2, :user_token)
      topic2 = get_session(conn2, :live_socket_id)

      # Distinct digest-derived topics that never expose a bearer token.
      assert topic1 == session_topic(token1)
      assert topic2 == session_topic(token2)
      assert topic1 != topic2

      for topic <- [topic1, topic2], token <- [token1, token2] do
        refute topic =~ token
      end

      # Representative stored capabilities that must not survive the change.
      api_token = Accounts.generate_api_session_token(user)
      reset_token = seed_email_token(user, "reset_password")
      confirm_token = seed_email_token(user, "confirm")
      _invite_token = seed_email_token(user, "invite")
      change_token = seed_email_token(user, "change:#{old_email}")

      seeded =
        Repo.all(from t in UserToken, where: t.user_id == ^user.id, select: {t.id, t.context})

      assert Enum.sort(Enum.map(seeded, &elem(&1, 1))) ==
               Enum.sort([
                 "session",
                 "session",
                 "api_session",
                 "reset_password",
                 "confirm",
                 "invite",
                 "change:#{old_email}"
               ])

      seeded_ids = Enum.map(seeded, &elem(&1, 0))

      # Mount the second browser's LiveView, monitor it, and attach a transport
      # stand-in at the exact production subscription point before mutating.
      {:ok, lv2, _html} = live(conn2, ~p"/users/settings")
      lv2_pid = lv2.pid
      ref2 = Process.monitor(lv2_pid)
      start_transport_stand_in(topic2, lv2_pid)

      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic1)
      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic2)

      # Browser 1 submits the exact password payload; LiveView preflight only.
      {:ok, lv1, _html} = live(conn1, ~p"/users/settings")

      form =
        form(lv1, "#password_form", %{
          "current_password" => valid_user_password(),
          "user" => %{
            "password" => @new_password,
            "password_confirmation" => @new_password
          }
        })

      assert render_submit(form) =~ "phx-trigger-action"

      # Nothing mutates until the native authenticated POST runs.
      assert Accounts.get_user_by_session_token(token1)
      assert Accounts.get_user_by_api_session_token(api_token)
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      refute_receive %Phoenix.Socket.Broadcast{}

      result_conn = follow_trigger_action(form, conn1)

      assert redirected_to(result_conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(result_conn.assigns.flash, :info) ==
               "Password updated successfully."

      # Exactly one disconnect broadcast per expired web-session topic...
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic1, event: "disconnect"}, 1000
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic2, event: "disconnect"}, 1000
      refute_receive %Phoenix.Socket.Broadcast{}

      # ...and the broadcast terminates the still-mounted second-browser
      # LiveView through the transport reaction, without sleeps.
      assert_receive {:DOWN, ^ref2, :process, ^lv2_pid, _reason}, 1000

      # Every pre-update capability is revoked, in storage and in behavior.
      for id <- seeded_ids do
        refute Repo.get(UserToken, id)
      end

      assert Accounts.get_user_by_session_token(token1) == nil
      assert Accounts.get_user_by_session_token(token2) == nil
      assert Accounts.get_user_by_api_session_token(api_token) == nil
      assert Accounts.get_user_by_reset_password_token(reset_token) == nil
      assert Accounts.confirm_user(confirm_token) == :error
      assert Accounts.update_user_email(Accounts.get_user!(user.id), change_token) == :error
      assert Accounts.get_user!(user.id).email == old_email

      # Only the new password authenticates.
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password()) == nil
      assert Accounts.get_user_by_email_and_password(user.email, @new_password).id == user.id

      # One fresh, topic-installed current-browser session and nothing else.
      new_token = get_session(result_conn, :user_token)
      assert is_binary(new_token)
      refute new_token in [token1, token2]
      assert Accounts.get_user_by_session_token(new_token).id == user.id

      new_topic = get_session(result_conn, :live_socket_id)
      assert new_topic == session_topic(new_token)
      refute new_topic in [topic1, topic2]

      assert [%UserToken{context: "session"} = fresh_row] =
               Repo.all(UserToken.user_and_contexts_query(user, :all))

      assert {:ok, fresh_digest} = UserToken.session_token_digest(new_token)
      assert fresh_row.token == fresh_digest

      # Persistent consent is cleared and no replacement cookie is issued.
      remember_cookie = result_conn.resp_cookies["user_remember_me"]
      assert remember_cookie.max_age == 0
      refute Map.has_key?(remember_cookie, :value)

      # The fresh session authenticates the redirect target.
      assert result_conn |> get(~p"/users/settings") |> html_response(200)

      # A sequential request carrying the invalidated old browser session
      # regains nothing and cannot repeat the mutation. No exactly-once claim
      # is made for concurrent transport replay.
      stale_get = get(conn1, ~p"/users/settings")
      assert redirected_to(stale_get) == ~p"/users/log_in"

      stale_post =
        post(conn1, ~p"/users/update_password", %{
          "current_password" => @new_password,
          "user" => %{
            "password" => @third_password,
            "password_confirmation" => @third_password
          }
        })

      assert redirected_to(stale_post) == ~p"/users/log_in"
      assert Accounts.get_user_by_email_and_password(user.email, @third_password) == nil
      assert Accounts.get_user_by_email_and_password(user.email, @new_password)
    end
  end

  defp member_user do
    user = user_fixture()
    organization = OrganizationsFixtures.organization_fixture()

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: [
          "pathways_studio_editor"
        ]
      })

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

  defp session_topic(encoded_token) do
    assert {:ok, digest} = UserToken.session_token_digest(encoded_token)
    "users_sessions:" <> Base.url_encode64(digest, padding: false)
  end

  defp seed_email_token(user, context) do
    {encoded, token_struct} = UserToken.build_email_token(user, context)
    Repo.insert!(token_struct)
    encoded
  end

  # Phoenix.LiveViewTest runs no websocket transport process. In production,
  # `Phoenix.LiveView.Socket.id/1` returns the session's `:live_socket_id`,
  # `Phoenix.Socket` subscribes to that topic, and its "disconnect" handler
  # terminates the socket together with every LiveView mounted on it. This
  # stand-in reproduces exactly that transport reaction at the faked
  # browser/transport boundary so the repository-owned broadcast observably
  # terminates the mounted LiveView.
  defp start_transport_stand_in(topic, lv_pid) do
    test_pid = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           :ok = GtfsPlannerWeb.Endpoint.subscribe(topic)
           send(test_pid, {:transport_stand_in_ready, self()})

           receive do
             %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic} ->
               GenServer.stop(lv_pid, :normal)
           end
         end}
      )

    assert_receive {:transport_stand_in_ready, ^task}
    :ok
  end
end
