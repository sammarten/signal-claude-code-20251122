defmodule SignalWeb.PageControllerTest do
  use SignalWeb.ConnCase

  test "GET / redirects to MarketLive", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Real-time Market Intelligence"
  end
end
