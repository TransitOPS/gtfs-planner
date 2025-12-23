defmodule GtfsPlannerWeb.Router do
  use GtfsPlannerWeb, :router
  import GtfsPlannerWeb.UserAuth
  import GtfsPlannerWeb.ApiKeyAuth

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
    plug :redirect_if_user_is_authenticated
  end

  pipeline :require_authenticated_user do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GtfsPlannerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
    plug :require_authenticated_user
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

    get "/", PageController, :home
  end

  scope "/", GtfsPlannerWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}] do
      live "/users/log_in", UserLoginLive, :new
      live "/users/reset_password", UserForgotPasswordLive, :new
      live "/users/reset_password/:token", UserResetPasswordLive, :edit
      live "/users/accept_invite/:token", UserAcceptInviteLive, :edit
    end
  end

  scope "/", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{GtfsPlannerWeb.UserAuth, :ensure_authenticated}] do
      live "/users/settings", UserSettingsLive, :edit
      live "/organizations", OrganizationsListLive, :index
    end
  end

  scope "/organizations/:org_alias", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user_and_org,
      on_mount: [{GtfsPlannerWeb.UserAuth, :ensure_authenticated}, GtfsPlannerWeb.AssignOrganization] do
      # Organization-specific routes will be added here
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", GtfsPlannerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:gtfs_planner, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
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
end
