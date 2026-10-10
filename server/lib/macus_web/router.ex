defmodule MacusWeb.Router do
  use MacusWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MacusWeb do
    pipe_through :api
  end
end
