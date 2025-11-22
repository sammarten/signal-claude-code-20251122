defmodule SignalWeb.PageController do
  use SignalWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
