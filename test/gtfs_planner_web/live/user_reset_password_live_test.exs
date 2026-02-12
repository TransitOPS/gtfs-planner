defmodule GtfsPlannerWeb.UserResetPasswordLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

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

  test "valid token mount renders reset password form", %{conn: conn, token: token} do
    {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

    assert has_element?(view, "#reset_password_form")
  end

  test "invalid token mount redirects with error flash", %{conn: conn} do
    assert {:error,
            {:redirect,
             %{to: "/", flash: %{"error" => "Reset password link is invalid or it has expired."}}}} =
             live(conn, ~p"/users/reset_password/invalid-token")
  end

  test "expired token mount redirects with error flash", %{conn: conn, user: user, token: token} do
    {:ok, decoded_token} = Base.url_decode64(token, padding: false)
    hashed_token = :crypto.hash(:sha256, decoded_token)

    update_query =
      from t in UserToken.token_and_context_query(hashed_token, "reset_password"),
        where: t.user_id == ^user.id

    {1, _} = Repo.update_all(update_query, set: [inserted_at: ~U[2020-01-01 00:00:00Z]])

    assert {:error,
            {:redirect,
             %{to: "/", flash: %{"error" => "Reset password link is invalid or it has expired."}}}} =
             live(conn, ~p"/users/reset_password/#{token}")
  end

  test "valid submit resets password and redirects to login", %{
    conn: conn,
    user: user,
    token: token
  } do
    {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

    view
    |> element("#reset_password_form")
    |> render_submit(%{
      "user" => %{
        "password" => "new valid password",
        "password_confirmation" => "new valid password"
      }
    })

    assert_redirect(view, ~p"/users/log_in")
    assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
  end

  test "invalid submit re-renders form with validation state", %{conn: conn, token: token} do
    {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

    view
    |> element("#reset_password_form")
    |> render_submit(%{
      "user" => %{
        "password" => "short",
        "password_confirmation" => "mismatch"
      }
    })

    assert has_element?(view, "#reset_password_form")
    assert has_element?(view, "#reset_password_form input.input-error")
  end
end
