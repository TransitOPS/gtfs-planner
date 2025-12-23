defmodule GtfsPlanner.Accounts.Emails.ResetPasswordEmail do
  @moduledoc """
  Module for sending password reset emails.
  """

  import Swoosh.Email

  alias GtfsPlanner.Mailer

  @doc """
  Delivers the password reset email.

  ## Examples

      iex> deliver(user, "https://example.com/users/reset_password/123")
      {:ok, %{to: ..., body: ...}}

  """
  def deliver(user, url) when is_binary(url) do
    new()
    |> to({user.email})
    |> from({"GTFS Planner", "no-reply@gtfsplanner.com"})
    |> subject("Reset your GTFS Planner password")
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
            <h1>Reset Your Password</h1>
          </div>
          <div class="content">
            <p>Hello,</p>
            <p>We received a request to reset your password for your GTFS Planner account. Click the button below to choose a new password.</p>
            <p>
              <a href="#{url}" class="button">Reset Password</a>
            </p>
            <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
            <p style="word-break: break-all; color: #3b82f6;">#{url}</p>
            <p>This reset link will expire in 24 hours.</p>
            <p>If you didn't request this password reset, you can safely ignore this email and your password will remain unchanged.</p>
          </div>
          <div class="footer">
            <p>&copy; #{DateTime.utc_now().year} GTFS Planner. All rights reserved.</p>
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp text_template(_user, url) do
    """
    Reset your GTFS Planner password

    Hello,

    We received a request to reset your password for your GTFS Planner account. Please visit the following link to choose a new password:

    #{url}

    This reset link will expire in 24 hours.

    If you didn't request this password reset, you can safely ignore this email and your password will remain unchanged.

    © #{DateTime.utc_now().year} GTFS Planner. All rights reserved.
    """
  end
end
