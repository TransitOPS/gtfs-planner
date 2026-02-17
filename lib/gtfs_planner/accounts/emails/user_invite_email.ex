defmodule GtfsPlanner.Accounts.Emails.UserInviteEmail do
  @moduledoc """
  Module for sending user invitation emails.
  """

  import Swoosh.Email

  alias GtfsPlanner.Mailer

  @doc """
  Delivers the user invitation email.

  ## Examples

      iex> deliver(user, "https://example.com/users/accept_invite/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver(user, url) when is_binary(url) do
    mail_domain = Application.get_env(:gtfs_planner, :mail_domain)

    new()
    |> to({user.email})
    |> from({"Pathways Studio", "no-reply@#{mail_domain}"})
    |> subject("You're invited to join Pathways Studio")
    |> html_body(html_template(user, url))
    |> text_body(text_template(user, url))
    |> Mailer.deliver()
  end

  # Private functions

  defp html_template(_user, url) do
    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8">
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 600px;
            margin: 0 auto;
            padding: 20px;
          }
          .container {
            background-color: #f9fafb;
            border-radius: 8px;
            padding: 30px;
          }
          .header {
            text-align: center;
            margin-bottom: 30px;
          }
          .header h1 {
            color: #111827;
            font-size: 24px;
            margin: 0;
          }
          .content {
            background-color: white;
            padding: 25px;
            border-radius: 6px;
            margin-bottom: 20px;
          }
          .button {
            display: inline-block;
            background-color: #3b82f6;
            color: white;
            text-decoration: none;
            padding: 12px 24px;
            border-radius: 6px;
            font-weight: 600;
            margin-top: 20px;
          }
          .button:hover {
            background-color: #2563eb;
          }
          .footer {
            text-align: center;
            color: #6b7280;
            font-size: 14px;
            margin-top: 30px;
          }
        </style>
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>You're Invited!</h1>
          </div>
          <div class="content">
            <p>Hello,</p>
            <p>You've been invited to join Pathways Studio. Click the button below to accept your invitation and set up your account.</p>
            <p>
              <a href="#{url}" class="button">Accept Invitation</a>
            </p>
            <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
            <p style="word-break: break-all; color: #3b82f6;">#{url}</p>
            <p>This invitation link will expire in 7 days.</p>
          </div>
          <div class="footer">
            <p>If you didn't expect this invitation, you can safely ignore this email.</p>
            <p>&copy; #{DateTime.utc_now().year} Pathways Studio. All rights reserved.</p>
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp text_template(_user, url) do
    """
    You're invited to join Pathways Studio

    Hello,

    You've been invited to join Pathways Studio. Please visit the following link to accept your invitation and set up your account:

    #{url}

    This invitation link will expire in 7 days.

    If you didn't expect this invitation, you can safely ignore this email.

    © #{DateTime.utc_now().year} Pathways Studio. All rights reserved.
    """
  end
end
