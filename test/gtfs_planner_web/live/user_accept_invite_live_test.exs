defmodule GtfsPlannerWeb.UserAcceptInviteLiveTest do
  use GtfsPlannerWeb.ConnCase
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.{UserOrgMembership, UserToken}
  alias GtfsPlanner.Repo

  @invalid_token_message "Invite link is invalid or it has expired."
  @success_message "Invitation accepted. Log in to continue."
  @has_password_message "You already have a password. Sign in to continue."
  @focus_payload %{form_id: "accept_invite_form", fallback_id: nil}

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
    email = "test-#{System.unique_integer()}@example.com"

    encoded_token =
      extract_user_token(fn _url ->
        Accounts.invite_member(
          email,
          organization.id,
          ["pathways_studio_editor"],
          &"http://localhost:4000/users/accept_invite/#{&1}",
          actor: admin
        )
      end)

    {:ok,
     user: Accounts.get_user_by_invite_token(encoded_token),
     token: encoded_token,
     organization: organization}
  end

  describe "valid invite render" do
    test "renders exact title, help, IDs, CTA, and form pending state", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      assert page_title(view) == "Set password · GTFS Planner · Pathways Studio"

      assert has_element?(view, ~s(#accept-invite-page[phx-hook="FormErrorFocus"]))
      refute has_element?(view, "#accept-invite-page[phx-update]")

      assert has_element?(
               view,
               ~s(#accept_invite_form[phx-change="validate"][phx-submit="accept_invite"][novalidate])
             )

      assert has_element?(view, ~s(#accept_invite_form[class~="phx-submit-loading:opacity-60"]))

      assert has_element?(
               view,
               ~s(#invite-password[name="user[password]"][type="password"][autocomplete="new-password"][required][phx-debounce="blur"][phx-blur="validate"][aria-describedby="invite-password-help"])
             )

      assert has_element?(
               view,
               ~s(#invite-password-confirmation[name="user[password_confirmation]"][type="password"][autocomplete="new-password"][required][phx-debounce="blur"][phx-blur="validate"])
             )

      refute has_element?(view, "#invite-password-confirmation[aria-describedby]")

      assert has_element?(view, "#accept-invite-submit")

      assert has_element?(
               view,
               "#invite-password-help",
               "At least 12 characters. A short phrase of a few words works well."
             )

      refute has_element?(view, "#invite-password-confirmation-help")
      refute has_element?(view, "#accept-invite-banner")

      html = render(view)

      submit = element(view, "#accept-invite-submit")
      assert render(submit) =~ "Set password"
      assert render(submit) =~ "Setting password…"

      h1s =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("h1")
        |> LazyHTML.to_tree()

      assert length(h1s) == 1
      assert has_element?(view, "h1#accept-invite-title", "Set password")

      assert has_element?(
               view,
               ~s(#accept-invite-login[href="/users/log_in"]),
               "Already set a password? Log in"
             )
    end
  end

  describe "auth frame" do
    test "renders both product logos above the card without the old wordmark", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      assert has_element?(
               view,
               ~s(#auth-brands img[alt='GTFS Planner'][src='/images/gtfs-planner-logo.svg'])
             )

      assert has_element?(
               view,
               ~s(#auth-brands img[alt='Pathways Studio'][src='/images/pathways-studio-logo.svg'])
             )

      html = render(view)
      refute html =~ "gtfs-logo.svg"
      refute has_element?(view, "#auth-brands .text-brand")
    end
  end

  describe "blur validation" do
    test "blur keeps untouched invite fields clean", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#invite-password")
      |> render_blur(%{
        "user" => %{
          "password" => "ab",
          "password_confirmation" => "",
          "_unused_password_confirmation" => ""
        }
      })

      assert has_element?(view, ~s(#invite-password[aria-invalid="true"]))
      assert has_element?(view, ~s(#invite-password-confirmation[aria-invalid="false"]))
    end

    test "blur on an empty field waits for submit instead of showing an error", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#invite-password")
      |> render_blur(%{
        "user" => %{
          "password" => "",
          "password_confirmation" => "",
          "_unused_password_confirmation" => ""
        }
      })

      assert has_element?(view, ~s(#invite-password[aria-invalid="false"]))
      refute has_element?(view, "#invite-password-error")
    end

    test "blur with a short password says how many characters to use", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#invite-password")
      |> render_blur(%{"user" => %{"password" => "short"}})

      assert has_element?(view, "#invite-password-error", "Use at least 12 characters.")
    end

    test "blur with a mismatched confirmation asks for the same password in both fields", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#invite-password-confirmation")
      |> render_blur(%{
        "user" => %{
          "password" => "a long enough password",
          "password_confirmation" => "a different password"
        }
      })

      assert has_element?(
               view,
               "#invite-password-confirmation-error",
               "Passwords don't match. Type the same password in both fields."
             )
    end

    test "metadata-only blur is a safe no-op", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#invite-password")
      |> render_blur()

      assert has_element?(view, ~s(#invite-password[aria-invalid="false"]))
      assert has_element?(view, ~s(#invite-password-confirmation[aria-invalid="false"]))
    end
  end

  describe "failed submit" do
    test "clears both secrets and focuses once", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{
          "password" => "secret-1",
          "password_confirmation" => "secret-2"
        }
      })

      html = render(view)
      refute html =~ "secret-1"
      refute html =~ "secret-2"

      password_value =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#invite-password")
        |> LazyHTML.attribute("value")

      assert password_value in [[], [""]]

      confirmation_value =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#invite-password-confirmation")
        |> LazyHTML.attribute("value")

      assert confirmation_value in [[], [""]]

      assert_push_event(view, "focus_form_error", @focus_payload)
      refute_push_event(view, "focus_form_error", @focus_payload)

      refute has_element?(view, "#flash-info")
      refute has_element?(view, "#flash-error")
    end

    test "explains in plain language what failed and why the fields are empty", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{"password" => "secret-1", "password_confirmation" => "secret-2"}
      })

      assert has_element?(
               view,
               ~s(#accept-invite-banner[role="alert"]),
               "Your password wasn't saved"
             )

      assert has_element?(view, "#accept-invite-banner", "We clear both password fields")
      assert has_element?(view, "#invite-password-error", "Use at least 12 characters.")

      assert has_element?(
               view,
               "#invite-password-confirmation-error",
               "Passwords don't match. Type the same password in both fields."
             )
    end

    test "a blank password asks for one", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{"user" => %{"password" => "", "password_confirmation" => ""}})

      assert has_element?(view, "#invite-password-error", "Enter a password.")
    end

    test "a blank confirmation asks for the password again", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{"password" => "a long enough password", "password_confirmation" => ""}
      })

      assert has_element?(
               view,
               "#invite-password-confirmation-error",
               "Enter the password again."
             )

      assert has_element?(view, ~s(#invite-password[aria-invalid="false"]))
    end

    test "a password over 72 characters states the limit", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")
      too_long = String.duplicate("a", 73)

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{"password" => too_long, "password_confirmation" => too_long}
      })

      assert has_element?(view, "#invite-password-error", "Use 72 characters or fewer.")
    end

    test "the banner stays while the person retypes, so the form does not shift", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{"password" => "secret-1", "password_confirmation" => "secret-2"}
      })

      view
      |> element("#accept_invite_form")
      |> render_change(%{
        "user" => %{
          "password" => "valid-password-123",
          "password_confirmation" => "valid-password-123"
        }
      })

      assert has_element?(view, "#accept-invite-banner")
      refute has_element?(view, "#invite-password-error")
    end

    test "correcting the secrets after a failed submit clears the errors", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{
          "password" => "secret-1",
          "password_confirmation" => "secret-2"
        }
      })

      assert_push_event(view, "focus_form_error", @focus_payload)

      view
      |> element("#accept_invite_form")
      |> render_change(%{
        "user" => %{
          "password" => "valid-password-123",
          "password_confirmation" => "valid-password-123"
        }
      })

      assert has_element?(view, ~s(#invite-password[aria-invalid="false"]))
      assert has_element?(view, ~s(#invite-password-confirmation[aria-invalid="false"]))
      refute_push_event(view, "focus_form_error", @focus_payload)
    end

    test "validate does not push focus event", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_change(%{
        "user" => %{
          "password" => "short",
          "password_confirmation" => "mismatch"
        }
      })

      refute_push_event(view, "focus_form_error", @focus_payload)
    end
  end

  describe "success" do
    test "consumes token and redirects with distinct info at login", %{
      conn: conn,
      token: token,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      result =
        view
        |> element("#accept_invite_form")
        |> render_submit(%{
          "user" => %{
            "password" => "valid-password-123",
            "password_confirmation" => "valid-password-123"
          }
        })

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ @success_message

      assert Accounts.get_user_by_email_and_password(user.email, "valid-password-123")
      assert Repo.get_by(UserToken, user_id: user.id, context: "invite") == nil
    end

    test "an organization_id added to the submitted payload grants no access", %{
      conn: conn,
      token: token,
      user: user,
      organization: organization
    } do
      other_organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{
          "password" => "valid-password-123",
          "password_confirmation" => "valid-password-123",
          "organization_id" => other_organization.id
        }
      })

      assert Accounts.get_user_by_email_and_password(user.email, "valid-password-123")

      refute Repo.get_by(UserOrgMembership,
               user_id: user.id,
               organization_id: other_organization.id
             )

      assert %UserOrgMembership{roles: ["pathways_studio_editor"]} =
               Repo.get_by(UserOrgMembership, user_id: user.id, organization_id: organization.id)
    end
  end

  describe "invalid/expired token" do
    test "invalid token redirects to login with error meaning", %{conn: conn} do
      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/accept_invite/invalid-token")
    end

    test "an account that already has a password is sent to log in without a set-password form",
         %{conn: conn} do
      existing = user_fixture()
      {encoded_token, user_token} = UserToken.build_email_token(existing, "invite")
      Repo.insert!(user_token)

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"info" => @has_password_message}}}} =
               live(conn, ~p"/users/accept_invite/#{encoded_token}")

      assert Accounts.get_user_by_email_and_password(existing.email, valid_user_password())
    end

    test "replayed token after success redirects to login", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_submit(%{
        "user" => %{
          "password" => "valid-password-123",
          "password_confirmation" => "valid-password-123"
        }
      })

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(build_conn(), ~p"/users/accept_invite/#{token}")
    end
  end

  describe "form name stability" do
    test "form name stays 'user' after validation error", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      view
      |> element("#accept_invite_form")
      |> render_change(%{
        "user" => %{
          "password" => "short",
          "password_confirmation" => "mismatch"
        }
      })

      assert has_element?(view, "#accept_invite_form")

      view
      |> element("#accept_invite_form")
      |> render_change(%{
        "user" => %{
          "password" => "validpassword123",
          "password_confirmation" => "validpassword123"
        }
      })

      assert has_element?(view, "#accept_invite_form")
    end
  end
end
