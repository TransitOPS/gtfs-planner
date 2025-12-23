defmodule GtfsPlanner.Accounts.UserNotifier do
  @moduledoc """
  Module for sending authentication-related emails to users.
  """

  use Phoenix.Swoosh, view: GtfsPlannerWeb.EmailLayouts, layout: {GtfsPlannerWeb.EmailLayouts, :email}

  alias GtfsPlanner.Mailer

  @doc """
  Delivers the email confirmation instructions.

  ## Examples

      iex> deliver_confirmation_instructions(user, "https://example.com/users/confirm/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_confirmation_instructions(user, url) when is_binary(url) do
    new()
    |> to({user.email})
    |> from({"GTFS Planner", "no-reply@gtfsplanner.com"})
    |> subject("Confirm your GTFS Planner email")
    |> render_body("confirmation_instructions.html", %{user: user, url: url})
    |> Mailer.deliver()
  end

  @doc """
  Delivers instructions to update a user's email.

  ## Examples

      iex> deliver_update_email_instructions(user, "https://example.com/users/settings/confirm_email/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_update_email_instructions(user, url) when is_binary(url) do
    new()
    |> to({user.email})
    |> from({"GTFS Planner", "no-reply@gtfsplanner.com"})
    |> subject("Update your GTFS Planner email")
    |> render_body("update_email_instructions.html", %{user: user, url: url})
    |> Mailer.deliver()
  end

  @doc """
  Delivers the password reset instructions.

  ## Examples

      iex> deliver_reset_password_instructions(user, "https://example.com/users/reset_password/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_reset_password_instructions(user, url) when is_binary(url) do
    new()
    |> to({user.email})
    |> from({"GTFS Planner", "no-reply@gtfsplanner.com"})
    |> subject("Reset your GTFS Planner password")
    |> render_body("reset_password_instructions.html", %{user: user, url: url})
    |> Mailer.deliver()
  end

  @doc """
  Delivers the user invitation email.

  ## Examples

      iex> deliver_user_invite(user, "https://example.com/users/accept_invite/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_invite(user, url) when is_binary(url) do
    new()
    |> to({user.email})
    |> from({"GTFS Planner", "no-reply@gtfsplanner.com"})
    |> subject("You're invited to join GTFS Planner")
    |> render_body("user_invite.html", %{user: user, url: url})
    |> Mailer.deliver()
  end

  ## Helpers

  defp extract_user_email(fun) when is_function(fun, 0), do: fun.()
end
