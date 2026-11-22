defmodule MedFabric.ExamWeb.Router do
  @moduledoc """
  Phoenix router owned by `med_fabric/apps/exam`.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", MedFabric.ExamWeb do
    pipe_through :browser

    live "/encounters/:encounter_id", ExamLive, :show
  end
end
