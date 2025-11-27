defmodule SignalWeb.SignalsLiveTest do
  use SignalWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Signal.Signals.TradeSignal
  alias Signal.Repo

  describe "SignalsLive" do
    setup do
      # Clean up any existing signals
      Repo.delete_all(TradeSignal)
      :ok
    end

    test "renders signals page with empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signals")

      assert html =~ "Trade Signals"
      assert html =~ "No Signals"
      assert html =~ "No signals match your current filters"
    end

    test "displays navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signals")

      assert html =~ "Market"
      assert html =~ "Signals"
    end

    test "shows grade filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signals")

      assert html =~ "Grade:"
      assert html =~ ~s(value="all")
      assert html =~ ~s(value="A")
      assert html =~ ~s(value="B")
      assert html =~ ~s(value="C")
    end

    test "shows direction filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signals")

      assert html =~ "Direction:"
      assert html =~ ~s(value="long")
      assert html =~ ~s(value="short")
    end

    test "shows status filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signals")

      assert html =~ "Status:"
      assert html =~ ~s(value="active")
      assert html =~ ~s(value="filled")
      assert html =~ ~s(value="expired")
    end

    test "displays signal when one exists", %{conn: conn} do
      # Create a test signal
      signal = create_test_signal()

      {:ok, _view, html} = live(conn, ~p"/signals")

      assert html =~ signal.symbol
      # Strategy name and direction (direction is lowercase in HTML, uppercase is CSS)
      assert html =~ "Break &amp; Retest"
      assert html =~ "long"
    end

    test "clicking a signal shows details panel", %{conn: conn} do
      signal = create_test_signal()

      {:ok, view, _html} = live(conn, ~p"/signals")

      # Click on the signal
      html = view |> element("[phx-click=select_signal]") |> render_click()

      assert html =~ "Signal Details"
      assert html =~ "Confluence Factors"
      assert html =~ signal.symbol
    end

    test "close details button works", %{conn: conn} do
      _signal = create_test_signal()

      {:ok, view, _html} = live(conn, ~p"/signals")

      # Select signal
      view |> element("[phx-click=select_signal]") |> render_click()

      # Close details
      html = view |> element("[phx-click=close_details]") |> render_click()

      assert html =~ "Select a Signal"
    end

    test "filter by grade works", %{conn: conn} do
      _signal_a = create_test_signal(quality_grade: "A")
      _signal_b = create_test_signal(quality_grade: "B", symbol: "TSLA")

      {:ok, view, _html} = live(conn, ~p"/signals")

      # Filter to only grade A
      html =
        view
        |> form("form", %{"filter" => %{"grade" => "A", "direction" => "all", "status" => "all"}})
        |> render_change()

      assert html =~ "AAPL"
      refute html =~ "TSLA"
    end

    test "filter by direction works", %{conn: conn} do
      _long_signal = create_test_signal(direction: "long")

      # Short signal needs stop above entry, target below entry
      _short_signal =
        create_test_signal(
          direction: "short",
          symbol: "TSLA",
          entry_price: Decimal.new("175.50"),
          stop_loss: Decimal.new("176.00"),
          take_profit: Decimal.new("174.50")
        )

      {:ok, view, _html} = live(conn, ~p"/signals")

      # Filter to only long
      html =
        view
        |> form("form", %{
          "filter" => %{"grade" => "all", "direction" => "long", "status" => "all"}
        })
        |> render_change()

      assert html =~ "AAPL"
      refute html =~ "TSLA"
    end

    test "stats summary shows correct counts", %{conn: conn} do
      _signal1 = create_test_signal(quality_grade: "A", status: "active")
      _signal2 = create_test_signal(quality_grade: "B", status: "filled", symbol: "TSLA")

      {:ok, _view, html} = live(conn, ~p"/signals")

      # Should show stats
      assert html =~ "Active"
      assert html =~ "Filled"
      assert html =~ "Grade A"
      assert html =~ "Grade B"
    end

    test "receives and displays new signals via PubSub", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/signals")

      # Initially no signals (with status filter showing active)
      assert html =~ "No Signals"

      # Create a signal and broadcast it
      signal = create_test_signal()

      # Simulate PubSub broadcast
      send(view.pid, {:signal_generated, signal})

      # View should update (direction is lowercase in HTML)
      html = render(view)
      assert html =~ signal.symbol
      assert html =~ "long"
    end

    test "updates signal status via PubSub", %{conn: conn} do
      signal = create_test_signal(status: "active")

      {:ok, view, _html} = live(conn, ~p"/signals")

      # Update signal to filled
      updated_signal = %{signal | status: "filled"}
      send(view.pid, {:signal_filled, updated_signal})

      # Change filter to show all statuses
      html =
        view
        |> form("form", %{
          "filter" => %{"grade" => "all", "direction" => "all", "status" => "all"}
        })
        |> render_change()

      assert html =~ "FILLED"
    end
  end

  # Helper functions

  defp create_test_signal(opts \\ []) do
    now = DateTime.utc_now()

    attrs = %{
      symbol: Keyword.get(opts, :symbol, "AAPL"),
      strategy: Keyword.get(opts, :strategy, "break_and_retest"),
      direction: Keyword.get(opts, :direction, "long"),
      entry_price: Keyword.get(opts, :entry_price, Decimal.new("175.50")),
      stop_loss: Keyword.get(opts, :stop_loss, Decimal.new("175.00")),
      take_profit: Keyword.get(opts, :take_profit, Decimal.new("176.50")),
      risk_reward: Keyword.get(opts, :risk_reward, Decimal.new("2.0")),
      confluence_score: Keyword.get(opts, :confluence_score, 9),
      quality_grade: Keyword.get(opts, :quality_grade, "B"),
      confluence_factors: %{
        "timeframe_alignment" => %{
          "score" => 3,
          "max_score" => 3,
          "present" => true,
          "details" => "All timeframes aligned"
        },
        "key_level_confluence" => %{
          "score" => 2,
          "max_score" => 2,
          "present" => true,
          "details" => "PDH level"
        },
        "price_action" => %{
          "score" => 1,
          "max_score" => 1,
          "present" => true,
          "details" => "Strong rejection"
        }
      },
      status: Keyword.get(opts, :status, "active"),
      generated_at: Keyword.get(opts, :generated_at, now),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 30 * 60, :second)),
      level_type: Keyword.get(opts, :level_type, "pdh"),
      level_price: Keyword.get(opts, :level_price, Decimal.new("175.30"))
    }

    %TradeSignal{}
    |> TradeSignal.changeset(attrs)
    |> Repo.insert!()
  end
end
