defmodule GtfsPlannerWeb.UserForgotPasswordLiveFailureTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import Swoosh.TestAssertions

  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  @common_message "If an account can receive password resets, instructions are on the way. Check your inbox and spam folder, or try again."

  setup do
    old_config = Application.get_env(:gtfs_planner, GtfsPlanner.Mailer)

    on_exit(fn ->
      Application.put_env(:gtfs_planner, GtfsPlanner.Mailer, old_config)
    end)

    %{old_config: old_config}
  end

  describe "mail adapter failure" do
    test "shares the login outcome, logs only a safe outcome class, and still inserts the token",
         %{conn: conn, old_config: old_config} do
      Application.put_env(
        :gtfs_planner,
        GtfsPlanner.Mailer,
        adapter: GtfsPlanner.MailerFailureAdapter
      )

      user = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      {result, log} =
        with_log(fn ->
          view
          |> element("#reset_password_form")
          |> render_submit(%{"user" => %{"email" => user.email}})
        end)

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      {:ok, conn} = follow_redirect(result, conn)
      failed_html = html_response(conn, 200)
      assert failed_html =~ @common_message
      refute failed_html =~ "flash-error"

      # The delivery path still inserts the reset token before the adapter runs.
      assert Repo.aggregate(
               UserToken.user_and_contexts_query(user, ["reset_password"]),
               :count,
               :id
             ) == 1

      # The failure may be logged as a safe outcome class only: never the
      # submitted address, the adapter reason, the token, or mail content.
      assert log =~ "could not be delivered"
      refute log =~ user.email
      refute log =~ "simulated_delivery_failure"
      refute log =~ "Swoosh"
      refute log =~ "reset_password/"

      # A successful delivery produces the browser-identical login flash.
      Application.put_env(:gtfs_planner, GtfsPlanner.Mailer, old_config)

      delivered_user = user_fixture()
      {:ok, delivered_view, _html} = live(conn, ~p"/users/reset_password")

      delivered_result =
        delivered_view
        |> element("#reset_password_form")
        |> render_submit(%{"user" => %{"email" => delivered_user.email}})

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = delivered_result

      {:ok, delivered_conn} = follow_redirect(delivered_result, conn)
      delivered_html = html_response(delivered_conn, 200)

      assert flash_text(delivered_html) =~ @common_message
      assert flash_text(failed_html) == flash_text(delivered_html)

      assert_email_sent(
        to: [{"", delivered_user.email}],
        subject: "Reset your Pathways Studio password"
      )
    end

    test "test adapter operational after restore from the failure test", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/users/reset_password")

      result =
        view
        |> element("#reset_password_form")
        |> render_submit(%{"user" => %{"email" => user.email}})

      assert {:error, {:redirect, %{to: "/users/log_in"}}} = result

      assert_email_sent(to: [{"", user.email}], subject: "Reset your Pathways Studio password")
    end
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
