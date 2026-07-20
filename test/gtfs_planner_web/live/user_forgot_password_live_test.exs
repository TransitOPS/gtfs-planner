defmodule GtfsPlannerWeb.UserForgotPasswordLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import Swoosh.TestAssertions

  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  @common_message "If an account can receive password resets, instructions are on the way. Check your inbox and spam folder, or try again."
  @focus_payload %{form_id: "reset_password_form", fallback_id: nil}

  describe "stable form contract" do
    test "renders the task copy, stable selectors, focus wiring, and pending contract", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      assert page_title(view) == "Reset password · Pathways Studio"
      assert has_element?(view, "h1", "Reset password")

      h1s =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("h1")
        |> LazyHTML.to_tree()

      assert length(h1s) == 1

      assert has_element?(view, ~s(#reset-password-request-page[phx-hook="FormErrorFocus"]))
      refute has_element?(view, "#reset-password-request-page[phx-update]")

      assert has_element?(
               view,
               ~s(#reset_password_form[phx-change="validate"][phx-submit="send_instructions"])
             )

      assert has_element?(view, ~s(#reset_password_form[class~="phx-submit-loading:opacity-60"]))

      assert has_element?(
               view,
               ~s(#reset-password-email[name="user[email]"][type="email"][required][phx-debounce="blur"][phx-blur="validate"])
             )

      assert has_element?(view, "#reset-password-request-submit", "Send reset link")

      assert has_element?(
               view,
               ~s(#reset-password-request-submit[phx-disable-with="Sending reset link…"])
             )

      refute has_element?(
               view,
               ~s(#reset-password-request-submit[class~="phx-submit-loading:opacity-60"])
             )

      assert has_element?(
               view,
               ~s(#reset_password_form a[href="/users/log_in"]),
               "Back to log in"
             )

      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
    end

    test "the email control is clean before interaction", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      assert has_element?(view, ~s(#reset-password-email[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-email-error")
    end
  end

  describe "blur validation" do
    test "blur with an invalid address validates the interacted control", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      view
      |> element("#reset-password-email")
      |> render_blur(%{"user" => %{"email" => "not-an-email"}})

      assert has_element?(
               view,
               ~s(#reset-password-email[aria-invalid="true"][value="not-an-email"])
             )

      assert has_element?(
               view,
               "#reset-password-email-error",
               "must have the @ sign and no spaces"
             )

      refute_push_event(view, "focus_form_error", @focus_payload)
    end

    test "a metadata-only blur event is a safe no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      view |> element("#reset-password-email") |> render_blur()

      assert has_element?(view, ~s(#reset-password-email[aria-invalid="false"]))
      refute has_element?(view, "#reset-password-email-error")
      assert has_element?(view, ~s(#reset_password_form[phx-submit="send_instructions"]))
      refute_push_event(view, "focus_form_error", @focus_payload)
    end

    test "blur with a padded valid address stays clean and renders the trimmed value", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      view
      |> element("#reset-password-email")
      |> render_blur(%{"user" => %{"email" => "  person@example.com  "}})

      assert has_element?(
               view,
               ~s(#reset-password-email[aria-invalid="false"][value="person@example.com"])
             )

      refute has_element?(view, "#reset-password-email-error")
    end
  end

  describe "invalid submit" do
    test "stays in flow, preserves the address, and pushes exactly one focus event", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      response =
        view
        |> element("#reset_password_form")
        |> render_submit(%{"user" => %{"email" => "not-an-email"}})

      assert is_binary(response)

      assert has_element?(
               view,
               ~s(#reset-password-email[aria-invalid="true"][value="not-an-email"])
             )

      assert has_element?(
               view,
               "#reset-password-email-error",
               "must have the @ sign and no spaces"
             )

      assert_push_event(view, "focus_form_error", @focus_payload)
      refute_push_event(view, "focus_form_error", @focus_payload)

      refute has_element?(view, "#flash-info")
      refute has_element?(view, "#flash-error")
    end

    test "a whitespace-only submit shows only the blank error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      view
      |> element("#reset_password_form")
      |> render_submit(%{"user" => %{"email" => "  "}})

      assert has_element?(view, "#reset-password-email-error", "can't be blank")

      refute has_element?(
               view,
               "#reset-password-email-error",
               "must have the @ sign and no spaces"
             )

      assert_push_event(view, "focus_form_error", @focus_payload)
      refute_push_event(view, "focus_form_error", @focus_payload)
    end

    test "correcting the address after a failed submit clears the error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      view
      |> element("#reset_password_form")
      |> render_submit(%{"user" => %{"email" => "not-an-email"}})

      assert has_element?(view, "#reset-password-email-error")
      assert_push_event(view, "focus_form_error", @focus_payload)

      view
      |> element("#reset_password_form")
      |> render_change(%{"user" => %{"email" => "person@example.com"}})

      assert has_element?(
               view,
               ~s(#reset-password-email[aria-invalid="false"][value="person@example.com"])
             )

      refute has_element?(view, "#reset-password-email-error")
      refute_push_event(view, "focus_form_error", @focus_payload)
    end
  end

  describe "shared login outcome" do
    test "an existing account redirects to login with the common message and delivers", %{
      conn: conn
    } do
      user = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      result =
        view
        |> element("#reset_password_form")
        |> render_submit(%{"user" => %{"email" => user.email}})

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ @common_message

      assert_email_sent(to: [{"", user.email}], subject: "Reset your Pathways Studio password")

      assert Repo.aggregate(
               UserToken.user_and_contexts_query(user, ["reset_password"]),
               :count,
               :id
             ) == 1
    end

    test "an absent account redirects to login with the common message and delivers nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      result =
        view
        |> element("#reset_password_form")
        |> render_submit(%{
          "user" => %{"email" => "absent-#{System.unique_integer([:positive])}@example.com"}
        })

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ @common_message

      refute_email_sent(subject: "Reset your Pathways Studio password")
    end

    test "absent and existing accounts render the identical login flash" do
      user = user_fixture()

      existing_html = submit_and_follow(build_conn(), user.email)

      absent_html =
        submit_and_follow(
          build_conn(),
          "absent-#{System.unique_integer([:positive])}@example.com"
        )

      assert flash_text(existing_html) =~ @common_message
      assert flash_text(existing_html) == flash_text(absent_html)
      refute absent_html =~ "flash-error"
    end
  end

  defp submit_and_follow(conn, email) do
    {:ok, view, _html} = live(conn, ~p"/users/reset_password")

    result =
      view
      |> element("#reset_password_form")
      |> render_submit(%{"user" => %{"email" => email}})

    assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

    {:ok, conn} = follow_redirect(result, conn)
    html_response(conn, 200)
  end

  defp flash_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-info")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
