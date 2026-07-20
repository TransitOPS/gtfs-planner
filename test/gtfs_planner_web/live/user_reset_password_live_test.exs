defmodule GtfsPlannerWeb.UserResetPasswordLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  @invalid_token_message "Reset password link is invalid or it has expired."
  @success_message "Password reset. Log in with your new password."
  @focus_payload %{form_id: "reset_password_form", fallback_id: nil}

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, fn token ->
          "#{url}/users/reset_password/#{token}"
        end)
      end)

    %{user: user, token: token}
  end

  describe "valid token form contract" do
    test "renders the task copy, stable selectors, focus wiring, and pending contract", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      assert page_title(view) == "Set new password · Pathways Studio"
      assert has_element?(view, "h1", "Set new password")

      h1s =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("h1")
        |> LazyHTML.to_tree()

      assert length(h1s) == 1

      assert has_element?(view, ~s(#reset-password-page[phx-hook="FormErrorFocus"]))
      refute has_element?(view, "#reset-password-page[phx-update]")

      assert has_element?(
               view,
               ~s(#reset_password_form[phx-change="validate"][phx-submit="reset_password"])
             )

      assert has_element?(view, ~s(#reset_password_form[class~="phx-submit-loading:opacity-60"]))

      assert has_element?(
               view,
               ~s(#reset-password-new-password[name="user[password]"][type="password"][required][phx-debounce="blur"][phx-blur="validate"][aria-describedby="reset-password-new-password-help"])
             )

      assert has_element?(
               view,
               "#reset-password-new-password-help",
               "Use 12–72 characters."
             )

      assert has_element?(
               view,
               ~s(#reset-password-confirmation[name="user[password_confirmation]"][type="password"][required][phx-debounce="blur"][phx-blur="validate"][aria-describedby="reset-password-confirmation-help"])
             )

      assert has_element?(
               view,
               "#reset-password-confirmation-help",
               "Must match the password above."
             )

      assert has_element?(view, "#reset-password-submit", "Reset password")

      assert has_element?(
               view,
               ~s(#reset-password-submit[phx-disable-with="Resetting password…"])
             )

      refute has_element?(
               view,
               ~s(#reset-password-submit[class~="phx-submit-loading:opacity-60"])
             )

      assert has_element?(
               view,
               ~s(#reset_password_form a[href="/users/log_in"]),
               "Back to log in"
             )

      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
    end

    test "both password controls are clean before interaction", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="false"]))
      assert has_element?(view, ~s(#reset-password-confirmation[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-new-password-error")
      refute has_element?(view, "#reset-password-confirmation-error")
    end
  end

  describe "blur validation" do
    test "blur with a short password validates only the interacted control", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      view
      |> element("#reset-password-new-password")
      |> render_blur(%{"user" => %{"password" => "short"}})

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="true"]))

      assert has_element?(
               view,
               "#reset-password-new-password-error",
               "should be at least 12 character(s)"
             )

      assert has_element?(view, ~s(#reset-password-confirmation[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-confirmation-error")
      refute_push_event(view, "focus_form_error", @focus_payload)
    end

    test "blur with a mismatched confirmation validates the confirmation control", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      view
      |> element("#reset-password-confirmation")
      |> render_blur(%{
        "user" => %{
          "password" => "new valid password",
          "password_confirmation" => "different valid password"
        }
      })

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-new-password-error")
      assert has_element?(view, ~s(#reset-password-confirmation[aria-invalid="true"]))

      assert has_element?(
               view,
               "#reset-password-confirmation-error",
               "does not match password"
             )

      refute_push_event(view, "focus_form_error", @focus_payload)
    end

    test "blur with a valid pair stays clean", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      view
      |> element("#reset-password-confirmation")
      |> render_blur(%{
        "user" => %{
          "password" => "new valid password",
          "password_confirmation" => "new valid password"
        }
      })

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="false"]))
      assert has_element?(view, ~s(#reset-password-confirmation[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-new-password-error")
      refute has_element?(view, "#reset-password-confirmation-error")
    end

    test "a metadata-only blur event is a safe no-op", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      view |> element("#reset-password-new-password") |> render_blur()

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-new-password-error")
      assert has_element?(view, ~s(#reset_password_form[phx-submit="reset_password"]))
      refute_push_event(view, "focus_form_error", @focus_payload)
    end
  end

  describe "failed submit" do
    test "stays in flow, retains errors, clears both secrets, and pushes one focus event", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      response =
        view
        |> element("#reset_password_form")
        |> render_submit(%{
          "user" => %{
            "password" => "secret-1",
            "password_confirmation" => "secret-2"
          }
        })

      assert is_binary(response)

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="true"]))

      assert has_element?(
               view,
               "#reset-password-new-password-error",
               "should be at least 12 character(s)"
             )

      assert has_element?(view, ~s(#reset-password-confirmation[aria-invalid="true"]))

      assert has_element?(
               view,
               "#reset-password-confirmation-error",
               "does not match password"
             )

      refute render(view) =~ "secret-1"
      refute render(view) =~ "secret-2"

      password_value =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#reset-password-new-password")
        |> LazyHTML.attribute("value")

      assert password_value in [[], [""]]

      confirmation_value =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#reset-password-confirmation")
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
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      view
      |> element("#reset_password_form")
      |> render_submit(%{
        "user" => %{
          "password" => "secret-1",
          "password_confirmation" => "secret-2"
        }
      })

      assert has_element?(view, "#reset-password-new-password-error")
      assert_push_event(view, "focus_form_error", @focus_payload)

      view
      |> element("#reset_password_form")
      |> render_change(%{
        "user" => %{
          "password" => "new valid password",
          "password_confirmation" => "new valid password"
        }
      })

      assert has_element?(view, ~s(#reset-password-new-password[aria-invalid="false"]))
      assert has_element?(view, ~s(#reset-password-confirmation[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-new-password-error")
      refute has_element?(view, "#reset-password-confirmation-error")
      refute_push_event(view, "focus_form_error", @focus_payload)
    end
  end

  describe "token outcomes" do
    test "an undecodable token redirects directly to login with the error meaning", %{
      conn: conn
    } do
      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/reset_password/invalid-token")
    end

    test "a well-shaped but unknown token fails closed at login", %{conn: conn} do
      unknown_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/reset_password/#{unknown_token}")
    end

    test "an expired token redirects directly to login with the error meaning", %{
      conn: conn,
      user: user,
      token: token
    } do
      {:ok, decoded_token} = Base.url_decode64(token, padding: false)
      hashed_token = :crypto.hash(:sha256, decoded_token)

      update_query =
        from t in UserToken.token_and_context_query(hashed_token, "reset_password"),
          where: t.user_id == ^user.id

      {1, _} = Repo.update_all(update_query, set: [inserted_at: ~U[2020-01-01 00:00:00Z]])

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/reset_password/#{token}")
    end

    test "a valid submit lands on login with the distinct info, changes the password, and deletes all tokens",
         %{conn: conn, user: user, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      result =
        view
        |> element("#reset_password_form")
        |> render_submit(%{
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ @success_message

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "a replayed token is rejected at login with the error meaning", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

      result =
        view
        |> element("#reset_password_form")
        |> render_submit(%{
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(build_conn(), ~p"/users/reset_password/#{token}")
    end
  end
end
