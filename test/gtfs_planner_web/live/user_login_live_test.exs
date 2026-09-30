defmodule GtfsPlannerWeb.UserLoginLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  alias GtfsPlanner.Organizations
  alias GtfsPlanner.OrganizationsFixtures

  @wrong_password "totally wrong password"

  describe "stable form contract" do
    test "renders the prototype login body, footer line, auth frame, and focus wiring", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/users/log_in")

      assert page_title(view) == "Log in · GTFS Planner · Pathways Studio"
      assert has_element?(view, "#login-title", "Log in")
      assert has_element?(view, ~s(#login-title[class~="text-[28px]"]))

      h1s =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("h1")
        |> LazyHTML.to_tree()

      assert length(h1s) == 1

      assert has_element?(
               view,
               ~s(#login-page[phx-hook="FormErrorFocus"][data-focus-on-mount="login-recovery"])
             )

      refute has_element?(view, "#login-page[phx-update]")

      assert has_element?(
               view,
               ~s(#login_form[action="/users/log_in"][method="post"][phx-update="ignore"][class~="mt-6"])
             )

      refute has_element?(view, "#login_form[phx-submit]")

      assert has_element?(
               view,
               ~s(label[for="login-email"][class~="text-sm"][class~="font-semibold"]),
               "Email"
             )

      assert has_element?(view, ~s(#login-email[name="user[email]"][type="email"][required]))

      assert has_element?(
               view,
               ~s(#login-email[class~="h-11"][class~="rounded-control"][class~="border-control"])
             )

      assert has_element?(
               view,
               ~s(label[for="login-password"][class~="text-sm"][class~="font-semibold"]),
               "Password"
             )

      assert has_element?(
               view,
               ~s(#login-password[name="user[password]"][type="password"][required])
             )

      assert has_element?(
               view,
               ~s(#login-password[class~="h-11"][class~="rounded-control"][class~="border-control"])
             )

      assert has_element?(view, ~s(label[for="login-remember-me"][class~="min-h-11"]))

      assert has_element?(view, ~s(#login-remember-me[name="user[remember_me]"][type="checkbox"]))

      assert has_element?(view, ~s(#login-remember-me[class~="accent-action"]))

      assert has_element?(
               view,
               ~s(label[for="login-remember-me"]),
               "Keep me logged in for 60 days"
             )

      assert has_element?(view, "#login-submit", "Log in")
      refute has_element?(view, "#login-submit", "→")

      assert has_element?(view, ~s(#login-submit[type="submit"][phx-disable-with="Logging in…"]))

      assert has_element?(
               view,
               ~s(#login-submit[class~="bg-action"][class~="w-full"][class~="rounded-control"])
             )

      assert has_element?(
               view,
               ~s(#login-page a[href="/users/reset_password"][class~="text-action"]),
               "Forgot your password?"
             )

      assert has_element?(
               view,
               "#main-content p",
               "No account? Ask your organization administrator for an invitation."
             )

      assert has_element?(view, ~s(#auth-brands img[alt="GTFS Planner"]))
      assert has_element?(view, ~s(#auth-brands img[alt="Pathways Studio"]))

      refute has_element?(view, "#login-recovery")
      refute has_element?(view, "#flash-error")
    end
  end

  describe "recovery callout" do
    test "invalid credentials render the error tone and fixed copy and preserve the email", %{
      conn: conn
    } do
      %{user: user} = member_user()

      view =
        conn
        |> post_log_in(user.email, @wrong_password)
        |> live_log_in()

      assert has_element?(
               view,
               ~s(#login-recovery[tabindex="-1"][class~="bg-error-bg"][class~="text-error-fg"]),
               "Email or password is incorrect"
             )

      assert has_element?(
               view,
               "#login-recovery",
               "Check both and try again."
             )

      assert has_element?(view, ~s(#login-email[value="#{user.email}"]))
      refute has_element?(view, "#flash-error")

      assert has_element?(
               view,
               ~s(#login-page[phx-hook="FormErrorFocus"][data-focus-on-mount="login-recovery"])
             )
    end

    test "an unknown email and a wrong password render the identical callout", %{conn: conn} do
      %{user: user} = member_user()

      wrong_password_view =
        conn
        |> post_log_in(user.email, @wrong_password)
        |> live_log_in()

      unknown_email_view =
        conn
        |> post_log_in(
          "absent-#{System.unique_integer([:positive])}@example.com",
          @wrong_password
        )
        |> live_log_in()

      assert render(element(wrong_password_view, "#login-recovery")) ==
               render(element(unknown_email_view, "#login-recovery"))
    end

    test "a deactivated member renders the warning tone and fixed deactivated callout", %{
      conn: conn
    } do
      %{user: user, organization: organization} = member_user()
      actor = system_admin_fixture(organization)
      {:ok, _} = Organizations.deactivate_user_in_organization(actor, user.id, organization.id)

      view =
        conn
        |> post_log_in(user.email, valid_user_password())
        |> live_log_in()

      assert has_element?(
               view,
               ~s(#login-recovery[tabindex="-1"][class~="bg-warning-bg"][class~="text-warning-fg"]),
               "Account deactivated"
             )

      assert has_element?(
               view,
               "#login-recovery",
               "Contact an administrator to restore access."
             )

      assert has_element?(view, ~s(#login-email[value="#{user.email}"]))
      refute has_element?(view, "#flash-error")
    end

    test "a member without an organization renders the warning tone and fixed organization callout",
         %{conn: conn} do
      user = user_fixture()

      view =
        conn
        |> post_log_in(user.email, valid_user_password())
        |> live_log_in()

      assert has_element?(
               view,
               ~s(#login-recovery[tabindex="-1"][class~="bg-warning-bg"][class~="text-warning-fg"]),
               "Organization access required"
             )

      assert has_element?(
               view,
               "#login-recovery",
               "Contact an administrator to add this account to an organization."
             )

      assert has_element?(view, ~s(#login-email[value="#{user.email}"]))
      refute has_element?(view, "#flash-error")
    end
  end

  describe "unknown or missing recovery codes" do
    test "an unknown recovery code renders no callout and still preserves the email", %{
      conn: conn
    } do
      conn =
        init_test_session(conn, %{
          "phoenix_flash" => %{
            "login_recovery" => "not_a_known_code",
            "email" => "person@example.com"
          }
        })

      {:ok, view, _html} = live(conn, ~p"/users/log_in")

      refute has_element?(view, "#login-recovery")
      assert has_element?(view, ~s(#login-email[value="person@example.com"]))
    end

    test "a missing recovery code renders no callout", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log_in")

      refute has_element?(view, "#login-recovery")
    end
  end

  describe "native session path" do
    test "valid member credentials issue a session through the unchanged native post", %{
      conn: conn
    } do
      %{user: user} = member_user()

      conn = post_log_in(conn, user.email, valid_user_password())

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
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

  defp post_log_in(conn, email, password) do
    post(conn, ~p"/users/log_in", %{"user" => %{"email" => email, "password" => password}})
  end

  defp live_log_in(conn) do
    {:ok, view, _html} = live(recycle(conn), ~p"/users/log_in")
    view
  end
end
