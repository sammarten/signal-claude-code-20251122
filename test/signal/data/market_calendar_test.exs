defmodule Signal.Data.MarketCalendarTest do
  use Signal.DataCase, async: false

  alias Signal.Data.MarketCalendar
  alias Signal.Data.MarketCalendarDay
  alias Signal.Repo

  describe "trading_day?/1" do
    test "returns true for stored trading days" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])

      assert MarketCalendar.trading_day?(~D[2024-01-02])
    end

    test "returns false for non-trading days" do
      refute MarketCalendar.trading_day?(~D[2024-01-01])
    end
  end

  describe "get_hours/1" do
    test "returns hours for trading day" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])

      assert {:ok, {~T[09:30:00], ~T[16:00:00]}} = MarketCalendar.get_hours(~D[2024-01-02])
    end

    test "returns error for non-trading day" do
      assert {:error, :not_trading_day} = MarketCalendar.get_hours(~D[2024-01-01])
    end

    test "returns early close hours" do
      insert_calendar_day(~D[2024-07-03], ~T[09:30:00], ~T[13:00:00])

      assert {:ok, {~T[09:30:00], ~T[13:00:00]}} = MarketCalendar.get_hours(~D[2024-07-03])
    end
  end

  describe "early_close?/1" do
    test "returns true for early close days" do
      insert_calendar_day(~D[2024-07-03], ~T[09:30:00], ~T[13:00:00])

      assert MarketCalendar.early_close?(~D[2024-07-03])
    end

    test "returns false for normal days" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])

      refute MarketCalendar.early_close?(~D[2024-01-02])
    end

    test "returns false for non-trading days" do
      refute MarketCalendar.early_close?(~D[2024-01-01])
    end
  end

  describe "market_open?/1" do
    setup do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])
      :ok
    end

    test "returns true during market hours" do
      # 10:30 AM ET = 15:30 UTC
      datetime = ~U[2024-01-02 15:30:00Z]
      assert MarketCalendar.market_open?(datetime)
    end

    test "returns false before market open" do
      # 9:00 AM ET = 14:00 UTC
      datetime = ~U[2024-01-02 14:00:00Z]
      refute MarketCalendar.market_open?(datetime)
    end

    test "returns false after market close" do
      # 4:30 PM ET = 21:30 UTC
      datetime = ~U[2024-01-02 21:30:00Z]
      refute MarketCalendar.market_open?(datetime)
    end

    test "returns true at exactly market open" do
      # 9:30 AM ET = 14:30 UTC
      datetime = ~U[2024-01-02 14:30:00Z]
      assert MarketCalendar.market_open?(datetime)
    end

    test "returns false at exactly market close" do
      # 4:00 PM ET = 21:00 UTC
      datetime = ~U[2024-01-02 21:00:00Z]
      refute MarketCalendar.market_open?(datetime)
    end

    test "returns false on non-trading day" do
      datetime = ~U[2024-01-01 15:30:00Z]
      refute MarketCalendar.market_open?(datetime)
    end
  end

  describe "trading_days_count/2" do
    test "counts trading days in range" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])
      insert_calendar_day(~D[2024-01-03], ~T[09:30:00], ~T[16:00:00])
      insert_calendar_day(~D[2024-01-04], ~T[09:30:00], ~T[16:00:00])

      assert MarketCalendar.trading_days_count(~D[2024-01-01], ~D[2024-01-05]) == 3
    end

    test "returns 0 when no trading days" do
      assert MarketCalendar.trading_days_count(~D[2024-01-01], ~D[2024-01-01]) == 0
    end
  end

  describe "trading_days_between/2" do
    test "returns all trading days in range" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])
      insert_calendar_day(~D[2024-01-03], ~T[09:30:00], ~T[16:00:00])
      insert_calendar_day(~D[2024-01-04], ~T[09:30:00], ~T[16:00:00])

      days = MarketCalendar.trading_days_between(~D[2024-01-01], ~D[2024-01-05])

      assert days == [~D[2024-01-02], ~D[2024-01-03], ~D[2024-01-04]]
    end

    test "returns empty list when no trading days" do
      assert MarketCalendar.trading_days_between(~D[2024-01-01], ~D[2024-01-01]) == []
    end
  end

  describe "expected_minutes/1" do
    test "returns minutes for normal trading day" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])

      assert MarketCalendar.expected_minutes(~D[2024-01-02]) == 390
    end

    test "returns minutes for early close day" do
      insert_calendar_day(~D[2024-07-03], ~T[09:30:00], ~T[13:00:00])

      assert MarketCalendar.expected_minutes(~D[2024-07-03]) == 210
    end

    test "returns 0 for non-trading day" do
      assert MarketCalendar.expected_minutes(~D[2024-01-01]) == 0
    end
  end

  describe "total_expected_minutes/2" do
    test "sums minutes across trading days" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])
      insert_calendar_day(~D[2024-01-03], ~T[09:30:00], ~T[16:00:00])

      assert MarketCalendar.total_expected_minutes(~D[2024-01-01], ~D[2024-01-05]) == 780
    end
  end

  describe "has_calendar_data?/2" do
    test "returns true when data exists" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])

      assert MarketCalendar.has_calendar_data?(~D[2024-01-01], ~D[2024-01-05])
    end

    test "returns false when no data" do
      refute MarketCalendar.has_calendar_data?(~D[2024-01-01], ~D[2024-01-05])
    end
  end

  describe "next_market_open/1" do
    test "returns current day open when market hasn't opened yet" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])

      # 9:00 AM ET = 14:00 UTC
      datetime = ~U[2024-01-02 14:00:00Z]

      assert {:ok, next_open} = MarketCalendar.next_market_open(datetime)
      # 9:30 AM ET = 14:30 UTC
      assert DateTime.to_date(next_open) == ~D[2024-01-02]
    end

    test "returns next day open after market close" do
      insert_calendar_day(~D[2024-01-02], ~T[09:30:00], ~T[16:00:00])
      insert_calendar_day(~D[2024-01-03], ~T[09:30:00], ~T[16:00:00])

      # 5:00 PM ET = 22:00 UTC
      datetime = ~U[2024-01-02 22:00:00Z]

      assert {:ok, next_open} = MarketCalendar.next_market_open(datetime)
      assert DateTime.to_date(next_open) == ~D[2024-01-03]
    end

    test "returns error when no future calendar data" do
      # No calendar data inserted
      datetime = ~U[2024-01-02 14:00:00Z]

      assert {:error, :no_calendar_data} = MarketCalendar.next_market_open(datetime)
    end
  end

  # Helper functions

  defp insert_calendar_day(date, open, close) do
    %MarketCalendarDay{}
    |> MarketCalendarDay.changeset(%{date: date, open: open, close: close})
    |> Repo.insert!()
  end
end
