defmodule GtfsPlannerWeb.UserConfirmationLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo

  @success_message "Email confirmed. Log in to continue."
  @invalid_token_message "Confirmation link is invalid or it has expired."

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_confirmation_instructions(user, fn token ->
          "#{url}/users/confirm/#{token}"
        end)
      end)

    %{user: user, token: token}
  end

  describe "valid token" do
    test "confirms once, redirects to login with the exact info, and consumes the token", %{
      conn: conn,
      user: user,
      token: token
    } do
      result = live(conn, ~p"/users/confirm/#{token}")

      assert {:error, {:redirect, %{to: "/users/log_in", flash: %{"info" => @success_message}}}} =
               result

      {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ @success_message

      assert Accounts.get_user!(user.id).confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id, context: "confirm")
    end
  end

  describe "invalid token" do
    test "an undecodable token redirects directly to login with the error meaning", %{conn: conn} do
      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/confirm/invalid-token")
    end

    test "a well-shaped but unknown token fails closed at login", %{conn: conn} do
      unknown_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/confirm/#{unknown_token}")
    end
  end

  describe "expired token" do
    test "a backdated-expired token redirects directly to login with the error meaning", %{
      conn: conn,
      user: user,
      token: token
    } do
      {:ok, decoded_token} = Base.url_decode64(token, padding: false)
      hashed_token = :crypto.hash(:sha256, decoded_token)

      update_query =
        from t in UserToken.token_and_context_query(hashed_token, "confirm"),
          where: t.user_id == ^user.id

      {1, _} = Repo.update_all(update_query, set: [inserted_at: ~U[2020-01-01 00:00:00Z]])

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(conn, ~p"/users/confirm/#{token}")

      refute Accounts.get_user!(user.id).confirmed_at
    end
  end

  describe "replayed token" do
    test "reusing a consumed confirmation link is rejected at login with the error meaning", %{
      conn: conn,
      token: token
    } do
      assert {:error, {:redirect, %{to: "/users/log_in", flash: %{"info" => @success_message}}}} =
               live(conn, ~p"/users/confirm/#{token}")

      assert {:error,
              {:redirect, %{to: "/users/log_in", flash: %{"error" => @invalid_token_message}}}} =
               live(build_conn(), ~p"/users/confirm/#{token}")
    end
  end

  describe "confirmation boundary" do
    test "the router exposes only the token confirmation route" do
      confirm_routes =
        GtfsPlannerWeb.Router.__routes__()
        |> Enum.filter(&(&1.path =~ "/users/confirm"))

      assert Enum.map(confirm_routes, & &1.path) == ["/users/confirm/:token"]
    end

    test "the tokenless resend branch is fully removed from the LiveView" do
      refute function_exported?(GtfsPlannerWeb.UserConfirmationLive, :handle_event, 3)
      refute function_exported?(GtfsPlannerWeb.UserConfirmationLive, :render, 1)
    end
  end
end
