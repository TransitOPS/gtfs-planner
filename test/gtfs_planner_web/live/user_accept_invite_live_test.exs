defmodule GtfsPlannerWeb.UserAcceptInviteLiveTest do
  use GtfsPlannerWeb.ConnCase
  import Phoenix.LiveViewTest
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  @invalid_token_message "Invite link is invalid or it has expired."
  @success_message "Invitation accepted. Log in to continue."
  @focus_payload %{form_id: "accept_invite_form", fallback_id: nil}

  setup do
    email = "test-#{System.unique_integer()}@example.com"
    {:ok, user} = Accounts.invite_user(email, nil)

    {encoded_token, user_token} = UserToken.build_email_token(user, "invite")
    Repo.insert!(user_token)

    {:ok, user: user, token: encoded_token}
  end

  describe "valid invite render" do
    test "renders exact title, help, IDs, CTA, and form pending state", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/accept_invite/#{token}")

      assert page_title(view) == "Set password · Pathways Studio"

      assert has_element?(view, ~s(#accept-invite-page[phx-hook="FormErrorFocus"]))
      refute has_element?(view, "#accept-invite-page[phx-update]")

      assert has_element?(
               view,
               ~s(#accept_invite_form[phx-change="validate"][phx-submit="accept_invite"])
             )

      assert has_element?(view, ~s(#accept_invite_form[class~="phx-submit-loading:opacity-60"]))

      assert has_element?(
               view,
               ~s(#invite-password[name="user[password]"][type="password"][required][phx-debounce="blur"][phx-blur="validate"][aria-describedby="invite-password-help"])
             )

      assert has_element?(
               view,
               ~s(#invite-password-confirmation[name="user[password_confirmation]"][type="password"][required][phx-debounce="blur"][phx-blur="validate"][aria-describedby="invite-password-confirmation-help"])
             )

      assert has_element?(view, "#accept-invite-submit")

      assert has_element?(view, "#invite-password-help")
      assert has_element?(view, "#invite-password-confirmation-help")

      html = render(view)
      assert html =~ "Use 12–72 characters."
      assert html =~ "Must match the password above."

      submit = element(view, "#accept-invite-submit")
      assert render(submit) =~ "Set password"
      assert render(submit) =~ "Setting password…"

      h1s =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("h1")
        |> LazyHTML.to_tree()

      assert length(h1s) == 1
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
  end

  describe "invalid/expired token" do
    test "invalid token redirects to login with error meaning", %{conn: conn} do
      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/accept_invite/invalid-token")
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
