defmodule GtfsPlanner.Accounts.UserTokenTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Accounts.UserToken

  describe "session_token_digest/1" do
    test "returns the exact digest stored for a generated web-session token" do
      user = user_fixture()
      {encoded_token, user_token} = UserToken.build_session_token(user)

      assert {:ok, digest} = UserToken.session_token_digest(encoded_token)
      assert digest == user_token.token
    end

    test "returns :error for malformed Base64 input" do
      assert :error = UserToken.session_token_digest("not-valid-base64!@#$")
    end

    test "does not return the raw or encoded token as the digest" do
      user = user_fixture()
      {encoded_token, _user_token} = UserToken.build_session_token(user)
      {:ok, raw_token} = Base.url_decode64(encoded_token, padding: false)

      assert {:ok, digest} = UserToken.session_token_digest(encoded_token)
      refute digest == raw_token
      refute digest == encoded_token
    end
  end

  describe "verify_session_token_query/1" do
    setup do
      user = user_fixture()
      {encoded_token, user_token} = UserToken.build_session_token(user)
      Repo.insert!(user_token)
      %{user: user, encoded_token: encoded_token}
    end

    test "resolves the persisted user for a valid token", %{
      user: user,
      encoded_token: encoded_token
    } do
      assert {:ok, query} = UserToken.verify_session_token_query(encoded_token)
      assert fetched_user = Repo.one(query)
      assert fetched_user.id == user.id
    end

    test "returns :error for malformed Base64 input" do
      assert :error = UserToken.verify_session_token_query("not-valid-base64!@#$")
    end

    test "queries by the same digest session_token_digest/1 computes", %{
      encoded_token: encoded_token
    } do
      assert {:ok, digest} = UserToken.session_token_digest(encoded_token)

      assert Repo.exists?(
               from(t in UserToken, where: t.token == ^digest and t.context == "session")
             )
    end

    test "does not match tokens with context \"api_session\"", %{user: user} do
      {api_token, api_user_token} = UserToken.build_api_session_token(user)
      Repo.insert!(api_user_token)

      assert {:ok, query} = UserToken.verify_session_token_query(api_token)
      refute Repo.one(query)
    end

    test "rejects tokens older than 60 days", %{encoded_token: encoded_token} do
      expired_at = DateTime.add(DateTime.utc_now(), -61, :day)

      Repo.update_all(
        from(t in UserToken, where: t.context == "session"),
        set: [inserted_at: expired_at]
      )

      assert {:ok, query} = UserToken.verify_session_token_query(encoded_token)
      refute Repo.one(query)
    end

    test "accepts tokens within the 60-day window", %{
      user: user,
      encoded_token: encoded_token
    } do
      recent_at = DateTime.add(DateTime.utc_now(), -59, :day)

      Repo.update_all(
        from(t in UserToken, where: t.context == "session"),
        set: [inserted_at: recent_at]
      )

      assert {:ok, query} = UserToken.verify_session_token_query(encoded_token)
      assert fetched_user = Repo.one(query)
      assert fetched_user.id == user.id
    end
  end

  describe "build_api_session_token/1" do
    test "returns a token string and a %UserToken{} with context \"api_session\"" do
      user = user_fixture()
      {token, user_token} = UserToken.build_api_session_token(user)

      assert is_binary(token)
      assert byte_size(token) > 0
      assert %UserToken{} = user_token
      assert user_token.context == "api_session"
      assert user_token.user_id == user.id
      assert is_binary(user_token.token)
    end

    test "generates unique tokens on each call" do
      user = user_fixture()
      {token1, _} = UserToken.build_api_session_token(user)
      {token2, _} = UserToken.build_api_session_token(user)

      assert token1 != token2
    end
  end

  describe "verify_api_session_token_query/1" do
    setup do
      user = user_fixture()
      {token, user_token} = UserToken.build_api_session_token(user)
      Repo.insert!(user_token)
      %{user: user, token: token}
    end

    test "returns {:ok, query} for a valid token", %{user: user, token: token} do
      assert {:ok, query} = UserToken.verify_api_session_token_query(token)
      assert fetched_user = Repo.one(query)
      assert fetched_user.id == user.id
    end

    test "returns :error for garbage input" do
      assert :error = UserToken.verify_api_session_token_query("not-valid-base64!@#$")
    end

    test "returns :error for a token that does not exist in the database" do
      fake_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      assert {:ok, query} = UserToken.verify_api_session_token_query(fake_token)
      refute Repo.one(query)
    end

    test "does not match tokens with context \"session\"", %{user: user} do
      {session_token, session_user_token} = UserToken.build_session_token(user)
      Repo.insert!(session_user_token)

      assert {:ok, query} = UserToken.verify_api_session_token_query(session_token)
      refute Repo.one(query)
    end

    test "rejects tokens older than 60 days", %{token: token} do
      expired_at = DateTime.add(DateTime.utc_now(), -61, :day)

      Repo.update_all(
        from(t in UserToken, where: t.context == "api_session"),
        set: [inserted_at: expired_at]
      )

      assert {:ok, query} = UserToken.verify_api_session_token_query(token)
      refute Repo.one(query)
    end

    test "accepts tokens within the 60-day window", %{user: user, token: token} do
      recent_at = DateTime.add(DateTime.utc_now(), -59, :day)

      Repo.update_all(
        from(t in UserToken, where: t.context == "api_session"),
        set: [inserted_at: recent_at]
      )

      assert {:ok, query} = UserToken.verify_api_session_token_query(token)
      assert fetched_user = Repo.one(query)
      assert fetched_user.id == user.id
    end
  end
end
