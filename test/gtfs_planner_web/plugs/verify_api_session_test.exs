defmodule GtfsPlannerWeb.Plugs.VerifyApiSessionTest do
  use GtfsPlannerWeb.ConnCase, async: true

  alias GtfsPlannerWeb.Plugs.VerifyApiSession

  import GtfsPlanner.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    token = GtfsPlanner.Accounts.generate_api_session_token(user)
    %{user: user, token: token, conn: conn}
  end

  describe "call/2" do
    test "assigns current_user, current_user_id, and api_session_token for valid Bearer token",
         %{conn: conn, user: user, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> VerifyApiSession.call([])

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_user_id == user.id
      assert conn.assigns.api_session_token == token
      refute conn.halted
    end

    test "returns 401 when Authorization header is missing", %{conn: conn} do
      conn = VerifyApiSession.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "unauthorized"}}
    end

    test "returns 401 for malformed Authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Token some-value")
        |> VerifyApiSession.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "unauthorized"}}
    end

    test "returns 401 for empty Bearer value", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> VerifyApiSession.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for expired token (>60 days)", %{conn: conn, user: user} do
      # Generate a token and insert it normally
      raw_token = GtfsPlanner.Accounts.generate_api_session_token(user)

      # Backdate the token beyond the 60-day window
      expired_at = DateTime.add(DateTime.utc_now(), -61, :day)

      {:ok, decoded} = Base.url_decode64(raw_token, padding: false)
      hashed_token = :crypto.hash(:sha256, decoded)

      import Ecto.Query

      {1, _} =
        GtfsPlanner.Repo.update_all(
          from(t in "users_tokens",
            where: t.token == ^hashed_token and t.context == "api_session"
          ),
          set: [inserted_at: expired_at]
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> VerifyApiSession.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "unauthorized"}}
    end

    test "returns 401 for web session token (context 'session')", %{conn: conn, user: user} do
      # Generate a web session token (context "session"), not an API session token
      web_token = GtfsPlanner.Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{web_token}")
        |> VerifyApiSession.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "unauthorized"}}
    end

    test "returns 401 for completely invalid token string", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-valid-base64!!!")
        |> VerifyApiSession.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end
end
