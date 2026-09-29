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
    |> from({"Pathways Studio", "no-reply@#{mail_domain}"})
    |> subject("Confirm your Pathways Studio email")
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
    |> from({"Pathways Studio", "no-reply@#{mail_domain}"})
    |> subject("Update your Pathways Studio email")
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
    |> from({"Pathways Studio", "no-reply@#{mail_domain}"})
    |> subject("Reset your Pathways Studio password")
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
    Logger.info("User invite sent to user #{user.id}")

    email_body = user_invite_html(user, url)
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to(user.email)
    |> from({"Pathways Studio", "no-reply@#{mail_domain}"})
    |> subject("You're invited to join Pathways Studio")
    |> html_body(email_body)
    |> Mailer.deliver()
  end

  @doc """
  Delivers a notice that the user was added to an organization and can sign in
  with their existing password. Carries no token.

  ## Examples

      iex> deliver_added_to_organization(user, "Acme Transit", "https://example.com/users/log_in")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_added_to_organization(user, organization_name, login_url)
      when is_binary(organization_name) and is_binary(login_url) do
    email_body = added_to_organization_html(user, organization_name, login_url)
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to(user.email)
    |> from({"Pathways Studio", "no-reply@#{mail_domain}"})
    |> subject("You've been added to #{organization_name}")
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
      You have been invited to join Pathways Studio. You can set your password by visiting the URL below:
    </p>
    <p>
      <a href="#{url}">Set your password</a>
    </p>
    <p>
      If you didn't request this invite, please ignore this.
    </p>
    """
  end

  defp added_to_organization_html(user, organization_name, login_url) do
    """
    <p>
      Hi #{user.email},
    </p>
    <p>
      You now have access to #{Plug.HTML.html_escape(organization_name)} in Pathways Studio. Sign in with your existing password:
    </p>
    <p>
      <a href="#{login_url}">Sign in</a>
    </p>
    """
  end
end
