defmodule GtfsPlannerWeb.Api.V1.AuthControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Api.V1.AuthController

  @password "valid user password 123456"
  @unauthorized_json %{"error" => %{"code" => "unauthorized"}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_user_with_org(_context) do
    user = user_fixture(%{password: @password})
    org = organization_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    %{user: user, org: org}
  end

  defp api_conn(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  defp call_login(conn, params) do
    conn
    |> api_conn()
    |> AuthController.login(params)
  end

  defp call_logout(conn, token) do
    conn
    |> api_conn()
    |> Plug.Conn.assign(:api_session_token, token)
    |> AuthController.logout(%{})
  end

  defp http_login(conn, email, password) do
    conn
    |> api_conn()
    |> post("/api/v1/auth/login", %{"email" => email, "password" => password})
  end

  defp http_logout(conn, token) do
    conn
    |> api_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> delete("/api/v1/auth/session")
  end

  defp persisted_api_session_token!(raw_token) do
    {:ok, decoded} = Base.url_decode64(raw_token, padding: false)
    hashed_token = :crypto.hash(:sha256, decoded)

    Repo.one!(
      from(t in UserToken,
        where: t.token == ^hashed_token and t.context == "api_session"
      )
    )
  end

  # ---------------------------------------------------------------------------
  # login/2
  # ---------------------------------------------------------------------------

  describe "login/2" do
    setup [:setup_user_with_org]

    test "returns 200 with token, user, organization membership, and expires_at for valid credentials",
         %{conn: conn, user: user, org: org} do
      conn = call_login(conn, %{"email" => user.email, "password" => @password})

      assert conn.status == 200
      body = json_response(conn, 200)

      assert %{"data" => data} = body
      assert is_binary(data["token"])
      assert data["user"]["id"] == user.id
      assert data["user"]["email"] == user.email
      assert data["organization_id"] == org.id
      assert data["roles"] == ["pathways_studio_editor"]
      assert is_binary(data["expires_at"])

      # Verify expires_at is roughly 60 days from now
      {:ok, expires_at, _} = DateTime.from_iso8601(data["expires_at"])
      diff = DateTime.diff(expires_at, DateTime.utc_now(), :second)
      # Should be between 59 and 61 days
      assert diff > 59 * 24 * 3600
      assert diff < 61 * 24 * 3600
    end

    test "HTTP login persists a user-owned api_session UserToken for the Bearer value",
         %{conn: conn, user: user, org: org} do
      conn = http_login(conn, user.email, @password)

      assert %{"data" => data} = json_response(conn, 200)
      assert is_binary(data["token"])
      assert data["user"]["id"] == user.id
      assert data["organization_id"] == org.id

      token_row = persisted_api_session_token!(data["token"])
      assert token_row.context == "api_session"
      assert token_row.user_id == user.id
      assert Accounts.get_user_by_api_session_token(data["token"]).id == user.id
    end

    test "returns 401 for invalid password", %{conn: conn, user: user} do
      conn = call_login(conn, %{"email" => user.email, "password" => "wrong"})

      assert conn.status == 401
      body = json_response(conn, 401)

      assert %{
               "error" => %{
                 "code" => "invalid_credentials",
                 "message" => "Invalid email or password."
               }
             } = body
    end

    test "returns 401 for nonexistent email with same error shape as invalid password",
         %{conn: conn} do
      conn = call_login(conn, %{"email" => "nobody@example.com", "password" => "wrong"})

      assert conn.status == 401
      body = json_response(conn, 401)

      assert %{
               "error" => %{
                 "code" => "invalid_credentials",
                 "message" => "Invalid email or password."
               }
             } = body
    end

    test "invalid password and nonexistent email share the same 401 JSON contract",
         %{conn: conn, user: user} do
      bad_password =
        call_login(conn, %{"email" => user.email, "password" => "wrong-password-value"})

      missing_user =
        call_login(build_conn(), %{
          "email" => "missing-user-#{System.unique_integer([:positive])}@example.com",
          "password" => "wrong-password-value"
        })

      assert json_response(bad_password, 401) == json_response(missing_user, 401)

      assert json_response(bad_password, 401) == %{
               "error" => %{
                 "code" => "invalid_credentials",
                 "message" => "Invalid email or password."
               }
             }
    end

    test "returns 403 for user with no org membership", %{conn: conn} do
      orphan = user_fixture(%{password: @password})

      conn = call_login(conn, %{"email" => orphan.email, "password" => @password})

      assert conn.status == 403
      body = json_response(conn, 403)

      assert %{"error" => %{"code" => "no_organization"}} = body
    end

    test "returns 403 for deactivated user", %{conn: conn, user: user, org: org} do
      GtfsPlanner.Organizations.deactivate_user_in_organization(user.id, org.id)

      conn = call_login(conn, %{"email" => user.email, "password" => @password})

      assert conn.status == 403
      body = json_response(conn, 403)
      # Deactivated memberships are filtered at the query level, so the user
      # appears to have no organization — the correct outcome either way.
      assert %{"error" => %{"code" => "no_organization"}} = body
    end

    test "returns 400 when email or password is missing", %{conn: conn} do
      conn_no_email = call_login(conn, %{"password" => "some"})
      assert conn_no_email.status == 400
      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn_no_email, 400)

      conn_no_pw = call_login(build_conn(), %{"email" => "a@b.com"})
      assert conn_no_pw.status == 400

      conn_empty = call_login(build_conn(), %{})
      assert conn_empty.status == 400
    end
  end

  # ---------------------------------------------------------------------------
  # logout/2
  # ---------------------------------------------------------------------------

  describe "logout/2" do
    setup [:setup_user_with_org]

    test "revokes the token so it is no longer valid", %{conn: conn, user: user} do
      token = Accounts.generate_api_session_token(user)

      # Verify token works before logout
      assert Accounts.get_user_by_api_session_token(token)

      conn = call_logout(conn, token)
      assert conn.status == 200

      # Token should no longer resolve to a user
      refute Accounts.get_user_by_api_session_token(token)
    end

    test "HTTP logout revokes the session and replay returns the unauthorized JSON body",
         %{conn: conn, user: user} do
      login = http_login(conn, user.email, @password)
      assert %{"data" => %{"token" => token}} = json_response(login, 200)

      logout = http_logout(build_conn(), token)
      assert %{"data" => %{"message" => "Logged out."}} = json_response(logout, 200)
      refute Accounts.get_user_by_api_session_token(token)
      refute Repo.get_by(UserToken, user_id: user.id, context: "api_session")

      replay =
        build_conn()
        |> api_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/versions")

      assert replay.status == 401
      assert json_response(replay, 401) == @unauthorized_json
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy-shaped Bearer rejection at the protected HTTP boundary
  # ---------------------------------------------------------------------------

  describe "legacy-shaped Bearer rejection" do
    test "Bearer GtfsPlanner.V1.<payload> receives unauthorized JSON on protected routes",
         %{conn: conn} do
      conn =
        conn
        |> api_conn()
        |> put_req_header("authorization", "Bearer GtfsPlanner.V1.legacy-payload")
        |> get("/api/v1/versions")

      assert conn.status == 401
      assert json_response(conn, 401) == @unauthorized_json
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :current_user_id)
      refute Map.has_key?(conn.assigns, :api_session_token)
      refute Map.has_key?(conn.assigns, :current_api_key)
    end
  end
end
