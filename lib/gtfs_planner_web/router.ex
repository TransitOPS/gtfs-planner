defmodule GtfsPlannerWeb.Router do
  use GtfsPlannerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GtfsPlannerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :redirect_if_user_is_authenticated do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GtfsPlannerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
    plug :redirect_if_user_is_authenticated_pl
  end

  pipeline :require_authenticated_user do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GtfsPlannerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
    plug :require_authenticated_user_pl
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_current_api_key
  end

  pipeline :api_organization do
    plug :accepts, ["json"]
    plug :fetch_current_api_key
    plug GtfsPlannerWeb.AssignOrganization
  end

  scope "/", GtfsPlannerWeb do
    pipe_through :browser

    post "/users/log_in", UserSessionController, :create
    delete "/users/log_out", UserSessionController, :delete
  end

  scope "/", GtfsPlannerWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}] do
      live "/users/register", UserRegistrationLive, :new
      live "/users/log_in", UserLoginLive, :new
      live "/users/reset_password", UserForgotPasswordLive, :new
      live "/users/reset_password/:token", UserResetPasswordLive, :edit
      live "/users/confirm/:token", UserConfirmationLive, :edit
      live "/users/accept_invite/:token", UserAcceptInviteLive, :edit
    end
  end

  scope "/", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{GtfsPlannerWeb.UserAuth, :ensure_authenticated}] do
      live "/", DashboardLive, :index
      live "/users/settings", UserSettingsLive, :edit
      live "/organizations", OrganizationsListLive, :index
    end
  end

  scope "/organizations/:org_alias", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user_and_org,
      on_mount: [
        {GtfsPlannerWeb.UserAuth, :ensure_authenticated},
        GtfsPlannerWeb.AssignOrganization
      ] do
      # Organization-specific routes will be added here
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", GtfsPlannerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:gtfs_planner, :dev_routes) do
    # If you want to use LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: GtfsPlannerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Private plug wrapper functions for external modules
  defp fetch_current_user(conn, opts), do: GtfsPlannerWeb.UserAuth.fetch_current_user(conn, opts)

  defp redirect_if_user_is_authenticated_pl(conn, opts),
    do: GtfsPlannerWeb.UserAuth.redirect_if_user_is_authenticated(conn, opts)

  defp require_authenticated_user_pl(conn, opts),
    do: GtfsPlannerWeb.UserAuth.require_authenticated_user(conn, opts)

  defp fetch_current_api_key(conn, opts),
    do: GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key(conn, opts)
end
