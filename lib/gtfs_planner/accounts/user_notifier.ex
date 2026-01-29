defmodule GtfsPlanner.Accounts.UserNotifier do
  @moduledoc """
  Module for sending authentication-related emails to users.
  """

  require Logger

  alias GtfsPlanner.Mailer
  import Swoosh.Email

  @doc """
  Delivers email confirmation instructions.

  ## Examples

      iex> deliver_confirmation_instructions(user, "https://example.com/users/confirm/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_confirmation_instructions(user, url) when is_binary(url) do
    email_body = confirmation_instructions_html(user, url)
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to(user.email)
    |> from({"GTFS Planner", "no-reply@#{mail_domain}"})
    |> subject("Confirm your GTFS Planner email")
    |> html_body(email_body)
    |> Mailer.deliver()
  end

  @doc """
  Delivers instructions to update a user's email.

  ## Examples

      iex> deliver_update_email_instructions(user, "https://example.com/users/settings/confirm_email/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_update_email_instructions(user, url) when is_binary(url) do
    email_body = update_email_instructions_html(user, url)
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to(user.email)
    |> from({"GTFS Planner", "no-reply@#{mail_domain}"})
    |> subject("Update your GTFS Planner email")
    |> html_body(email_body)
    |> Mailer.deliver()
  end

  @doc """
  Delivers password reset instructions.

  ## Examples

      iex> deliver_reset_password_instructions(user, "https://example.com/users/reset_password/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_reset_password_instructions(user, url) when is_binary(url) do
    email_body = reset_password_instructions_html(user, url)
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to(user.email)
    |> from({"GTFS Planner", "no-reply@#{mail_domain}"})
    |> subject("Reset your GTFS Planner password")
    |> html_body(email_body)
    |> Mailer.deliver()
  end

  @doc """
  Delivers user invitation email.

  ## Examples

      iex> deliver_user_invite(user, "https://example.com/users/accept_invite/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_invite(user, url) when is_binary(url) do
    Logger.info("User invite for #{user.email}: #{url}")

    email_body = user_invite_html(user, url)
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to(user.email)
    |> from({"GTFS Planner", "no-reply@#{mail_domain}"})
    |> subject("You're invited to join GTFS Planner")
    |> html_body(email_body)
    |> Mailer.deliver()
  end

  # Helper functions to generate email HTML
  defp confirmation_instructions_html(user, url) do
    """
    <p>
      Hello #{user.email},
    </p>
    <p>
      You can confirm your account email by visiting the URL below:
    </p>
    <p>
      <a href="#{url}">Confirm your account</a>
    </p>
    <p>
      If you didn't create an account with us, please ignore this.
    </p>
    """
  end

  defp update_email_instructions_html(user, url) do
    """
    <p>
      Hi #{user.email},
    </p>
    <p>
      You can change your email by visiting the URL below:
    </p>
    <p>
      <a href="#{url}">Change your email</a>
    </p>
    <p>
      If you didn't request this change, please ignore this.
    </p>
    """
  end

  defp reset_password_instructions_html(user, url) do
    """
    <p>
      Hello #{user.email},
    </p>
    <p>
      You can reset your password by visiting the URL below:
    </p>
    <p>
      <a href="#{url}">Reset your password</a>
    </p>
    <p>
      If you didn't request this change, please ignore this.
    </p>
    """
  end

  defp user_invite_html(user, url) do
    """
    <p>
      Hi #{user.email},
    </p>
    <p>
      You have been invited to join GTFS Planner. You can set your password by visiting the URL below:
    </p>
    <p>
      <a href="#{url}">Set your password</a>
    </p>
    <p>
      If you didn't request this invite, please ignore this.
    </p>
    """
  end
end
