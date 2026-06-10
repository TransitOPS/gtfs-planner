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

  scope "/", GtfsPlannerWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/", GtfsPlannerWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    post "/users/log_in", UserSessionController, :create

    live_session :redirect_if_user_is_authenticated,
      on_mount: [{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}] do
      live "/first", FirstAdminLive, :index
      live "/users/log_in", UserLoginLive, :new
      live "/users/reset_password", UserForgotPasswordLive, :new
      live "/users/reset_password/:token", UserResetPasswordLive, :edit
      live "/users/confirm/:token", UserConfirmationLive, :edit
      live "/users/accept_invite/:token", UserAcceptInviteLive, :edit
    end
  end

  scope "/", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    delete "/users/log_out", UserSessionController, :delete
    get "/station-data-resolution-prototype", StationResolutionPrototypeController, :index

    get "/station-data-resolution-prototype/station-resolution-v2.css",
        StationResolutionPrototypeController,
        :stylesheet

    get "/map/tiles/:style/:z/:x/:y", MapTilesController, :show
    get "/map/buildings", MapBuildingsController, :index

    live_session :require_authenticated_user,
      on_mount: [{GtfsPlannerWeb.UserAuth, :ensure_authenticated}] do
      live "/", DashboardLive, :index
      live "/users/settings", UserSettingsLive, :edit
      live "/components", ComponentsLive, :index
    end
  end

  scope "/admin", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user_and_org,
      on_mount: [
        {GtfsPlannerWeb.UserAuth, :ensure_authenticated},
        GtfsPlannerWeb.AssignOrganization
      ] do
      # Admin routes (pathways_studio_admin role required)
      live "/users", Admin.UsersLive, :index
      live "/users/invite", Admin.UsersLive, :invite
      live "/users/organization-settings", Admin.UsersLive, :organization_settings
      live "/users/:user_id", Admin.UsersLive, :show
    end
  end

  scope "/admin/organizations", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :administrator_only,
      on_mount: [
        {GtfsPlannerWeb.UserAuth, :ensure_authenticated},
        {GtfsPlannerWeb.EnsureRole, :require_system_administrator}
      ] do
      # Organization management routes (administrator role required)
      live "/", Admin.OrganizationsLive, :index
      live "/new", Admin.OrganizationsLive, :new
      live "/:org_id", Admin.OrganizationsLive, :show
      live "/:org_id/edit", Admin.OrganizationsLive, :edit
      live "/:org_id/invite", Admin.OrganizationsLive, :invite
    end
  end

  scope "/gtfs/:version", GtfsPlannerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :gtfs_routes,
      on_mount: [
        {GtfsPlannerWeb.UserAuth, :ensure_authenticated},
        GtfsPlannerWeb.AssignOrganization,
        GtfsPlannerWeb.AssignGtfsVersion
      ] do
      # GTFS routes (viewer or editor roles required)
      live "/routes", Gtfs.RoutesLive, :index
      live "/routes/:route_id", Gtfs.RouteDetailLive, :details
      live "/routes/:route_id/patterns", Gtfs.RouteDetailLive, :patterns
      live "/routes/:route_id/schedules", Gtfs.RouteDetailLive, :schedules
      live "/stops", Gtfs.StopsLive, :index
      live "/stops/:stop_id", Gtfs.StopDetailLive, :show
      live "/stops/:stop_id/diagram", Gtfs.StationDiagramLive, :index
      live "/stops/:stop_id/report", Gtfs.StationReport2Live, :index
      live "/stops/:stop_id/reachability", Gtfs.StationReachabilityLive, :index
      live "/import", Gtfs.ImportLive, :index
      live "/export", Gtfs.ExportLive, :index
      live "/validation/:validation_id", Gtfs.ValidationResultLive, :show
      live "/station-reachability/:validation_id", Gtfs.StationReachabilityResultLive, :show
    end
  end

  # -- Companion API pipelines --------------------------------------------------

  pipeline :api_cors do
    plug :accepts, ["json"]
    plug GtfsPlannerWeb.Plugs.CORS
  end

  pipeline :api_session do
    plug :accepts, ["json"]
    plug GtfsPlannerWeb.Plugs.CORS
    plug GtfsPlannerWeb.Plugs.VerifyApiSession
    plug GtfsPlannerWeb.Plugs.AssignApiOrganization
  end

  # API routes that WRITE GTFS data additionally require the editor role —
  # the API counterpart of the desktop's EnsureRole :require_gtfs_access.
  pipeline :api_editor do
    plug GtfsPlannerWeb.Plugs.RequireApiEditorRole
  end

  # -- Companion API routes ----------------------------------------------------

  # CORS preflight — must be before authenticated routes
  scope "/api/v1" do
    pipe_through :api_cors

    options "/*path", GtfsPlannerWeb.Api.V1.FallbackController, :preflight
  end

  # Public API routes (no auth required)
  scope "/api/v1", GtfsPlannerWeb.Api.V1 do
    pipe_through :api_cors

    post "/auth/login", AuthController, :login
  end

  # Protected API routes (auth required)
  scope "/api/v1", GtfsPlannerWeb.Api.V1 do
    pipe_through :api_session

    delete "/auth/session", AuthController, :logout

    get "/versions", VersionController, :index
    get "/versions/:version_id/stations", StationController, :index
    get "/versions/:version_id/stations/:station_id/bundle", StationController, :bundle
    post "/versions/:version_id/stations/:station_id/sync", SyncController, :create
  end

  # Protected API routes that write GTFS data (editor role required)
  scope "/api/v1", GtfsPlannerWeb.Api.V1 do
    pipe_through [:api_session, :api_editor]

    put "/versions/:version_id/stations/:station_id/levels/:level_id/alignment",
        LevelAlignmentController,
        :update
  end

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
