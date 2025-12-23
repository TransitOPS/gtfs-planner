defmodule GtfsPlanner.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Accounts` context.
  """

  @doc """
  Generate a unique user email.
  """
  def unique_user_email, do: "user#{System.unique_integer()}@example.com"

  @doc """
  Generate a valid user password.
  """
  def valid_user_password, do: "hello world!12345678"

  @doc """
  Generate valid user attributes.
  """
  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  @doc """
  Generate a user fixture.
  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> GtfsPlanner.Accounts.register_user()

    user
  end

  @doc """
  Extract the token from a confirmation/reset email sent to the given user.
  """
  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"http://localhost:4000#{&1}")
    # Extract the token from the URL in the email
    [_, token] = Regex.run(~r/\/users\/[^\/]+\/([^"\s]+)/, captured_email.html_body)
    token
  end
end
