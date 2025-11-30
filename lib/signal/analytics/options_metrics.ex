defmodule Signal.Analytics.OptionsMetrics do
  @moduledoc """
  Calculates options-specific performance metrics from a list of options trades.

  Extends the base TradeMetrics with options-specific analytics including:

  - **Premium Stats**: Average entry/exit premium, premium capture rate
  - **Exit Reason Analysis**: Breakdown by expiration, premium target, stop, etc.
  - **Contract Type Analysis**: Calls vs puts performance
  - **Expiration Analysis**: Performance by DTE and expiration type
  - **Strike Analysis**: Performance by strike distance (ATM, OTM, etc.)
  - **Greeks Impact**: Delta exposure and directional accuracy (future)

  ## Usage

      options_trades = Enum.filter(trades, &(&1.instrument_type == "options"))
      {:ok, metrics} = OptionsMetrics.calculate(options_trades)

      metrics.avg_premium_capture  # => Decimal.new("1.85")
      metrics.by_exit_reason       # => %{expiration: %{count: 5, ...}, ...}
  """

  alias Signal.Analytics.TradeMetrics

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  defstruct [
    # Base trade metrics
    :base_metrics,

    # Premium statistics
    :avg_entry_premium,
    :avg_exit_premium,
    :avg_premium_change,
    :avg_premium_change_pct,
    :total_premium_collected,
    :total_premium_paid,

    # Premium capture (how much of potential profit was captured)
    :avg_premium_capture_multiple,

    # Contract statistics
    :total_contracts,
    :avg_contracts_per_trade,

    # Exit reason breakdown
    :by_exit_reason,

    # Contract type breakdown
    :by_contract_type,

    # Expiration analysis
    :by_expiration_type,
    :avg_dte_at_entry,

    # Strike analysis
    :by_strike_distance
  ]

  @type t :: %__MODULE__{
          base_metrics: TradeMetrics.t(),
          avg_entry_premium: Decimal.t() | nil,
          avg_exit_premium: Decimal.t() | nil,
          avg_premium_change: Decimal.t() | nil,
          avg_premium_change_pct: Decimal.t() | nil,
          total_premium_collected: Decimal.t(),
          total_premium_paid: Decimal.t(),
          avg_premium_capture_multiple: Decimal.t() | nil,
          total_contracts: non_neg_integer(),
          avg_contracts_per_trade: Decimal.t() | nil,
          by_exit_reason: map(),
          by_contract_type: map(),
          by_expiration_type: map(),
          avg_dte_at_entry: non_neg_integer() | nil,
          by_strike_distance: map()
        }

  @doc """
  Calculates options-specific metrics from a list of closed options trades.

  ## Parameters

    * `trades` - List of trade maps with options fields:
      * `:instrument_type` - Should be "options"
      * `:entry_premium` - Entry price of the option
      * `:exit_premium` - Exit price of the option
      * `:num_contracts` - Number of contracts
      * `:contract_type` - "call" or "put"
      * `:expiration_date` - Contract expiration
      * `:strike` - Strike price
      * `:options_exit_reason` - Reason for exit
      * Standard trade fields (pnl, r_multiple, etc.)

  ## Returns

    * `{:ok, %OptionsMetrics{}}` - Metrics calculated successfully
    * `{:error, reason}` - Calculation failed
  """
  @spec calculate(list(map())) :: {:ok, t()} | {:error, term()}
  def calculate(trades) when is_list(trades) do
    # Filter to only options trades
    options_trades =
      Enum.filter(trades, fn trade ->
        Map.get(trade, :instrument_type) == "options"
      end)

    if Enum.empty?(options_trades) do
      {:ok, empty_metrics()}
    else
      {:ok, do_calculate(options_trades)}
    end
  end

  @doc """
  Calculates metrics for a specific exit reason.
  """
  @spec metrics_for_exit_reason(list(map()), String.t()) :: map()
  def metrics_for_exit_reason(trades, exit_reason) do
    filtered = Enum.filter(trades, &(Map.get(&1, :options_exit_reason) == exit_reason))
    calculate_group_metrics(filtered)
  end

  @doc """
  Calculates metrics for a specific contract type (call/put).
  """
  @spec metrics_for_contract_type(list(map()), String.t()) :: map()
  def metrics_for_contract_type(trades, contract_type) do
    filtered = Enum.filter(trades, &(Map.get(&1, :contract_type) == contract_type))
    calculate_group_metrics(filtered)
  end

  # Private Functions

  defp do_calculate(trades) do
    # Calculate base metrics
    {:ok, base_metrics} = TradeMetrics.calculate(trades)

    # Premium statistics
    premium_stats = calculate_premium_stats(trades)

    # Contract statistics
    total_contracts = sum_contracts(trades)

    avg_contracts =
      if length(trades) > 0, do: div_decimal(total_contracts, length(trades)), else: nil

    # Breakdowns
    by_exit_reason = group_by_exit_reason(trades)
    by_contract_type = group_by_contract_type(trades)
    by_expiration_type = group_by_expiration_type(trades)
    by_strike_distance = group_by_strike_distance(trades)

    # DTE analysis
    avg_dte = calculate_avg_dte(trades)

    %__MODULE__{
      base_metrics: base_metrics,
      avg_entry_premium: premium_stats.avg_entry,
      avg_exit_premium: premium_stats.avg_exit,
      avg_premium_change: premium_stats.avg_change,
      avg_premium_change_pct: premium_stats.avg_change_pct,
      total_premium_collected: premium_stats.total_collected,
      total_premium_paid: premium_stats.total_paid,
      avg_premium_capture_multiple: premium_stats.avg_capture_multiple,
      total_contracts: total_contracts,
      avg_contracts_per_trade: avg_contracts,
      by_exit_reason: by_exit_reason,
      by_contract_type: by_contract_type,
      by_expiration_type: by_expiration_type,
      avg_dte_at_entry: avg_dte,
      by_strike_distance: by_strike_distance
    }
  end

  defp empty_metrics do
    %__MODULE__{
      base_metrics: empty_base_metrics(),
      avg_entry_premium: nil,
      avg_exit_premium: nil,
      avg_premium_change: nil,
      avg_premium_change_pct: nil,
      total_premium_collected: @zero,
      total_premium_paid: @zero,
      avg_premium_capture_multiple: nil,
      total_contracts: 0,
      avg_contracts_per_trade: nil,
      by_exit_reason: %{},
      by_contract_type: %{},
      by_expiration_type: %{},
      avg_dte_at_entry: nil,
      by_strike_distance: %{}
    }
  end

  defp empty_base_metrics do
    {:ok, metrics} = TradeMetrics.calculate([])
    metrics
  end

  defp calculate_premium_stats(trades) do
    trades_with_premium =
      Enum.filter(trades, fn trade ->
        Map.get(trade, :entry_premium) != nil
      end)

    if Enum.empty?(trades_with_premium) do
      %{
        avg_entry: nil,
        avg_exit: nil,
        avg_change: nil,
        avg_change_pct: nil,
        total_collected: @zero,
        total_paid: @zero,
        avg_capture_multiple: nil
      }
    else
      entry_premiums = Enum.map(trades_with_premium, &get_decimal(&1, :entry_premium))
      exit_premiums = Enum.map(trades_with_premium, &get_decimal(&1, :exit_premium))

      avg_entry = average(entry_premiums)
      avg_exit = average(exit_premiums)

      # Calculate premium changes
      changes =
        Enum.map(trades_with_premium, fn trade ->
          entry = get_decimal(trade, :entry_premium)
          exit = get_decimal(trade, :exit_premium)
          Decimal.sub(exit, entry)
        end)

      avg_change = average(changes)

      # Calculate percentage changes
      pct_changes =
        Enum.map(trades_with_premium, fn trade ->
          entry = get_decimal(trade, :entry_premium)
          exit = get_decimal(trade, :exit_premium)

          if Decimal.compare(entry, @zero) == :gt do
            Decimal.div(Decimal.sub(exit, entry), entry) |> Decimal.mult(@hundred)
          else
            @zero
          end
        end)

      avg_change_pct = average(pct_changes)

      # Total premiums (for long options, entry is paid, exit is collected)
      total_paid = Enum.reduce(entry_premiums, @zero, &Decimal.add/2)
      total_collected = Enum.reduce(exit_premiums, @zero, &Decimal.add/2)

      # Premium capture multiple (exit / entry average)
      avg_capture_multiple =
        if avg_entry && Decimal.compare(avg_entry, @zero) == :gt do
          Decimal.div(avg_exit, avg_entry) |> Decimal.round(2)
        else
          nil
        end

      %{
        avg_entry: avg_entry,
        avg_exit: avg_exit,
        avg_change: avg_change,
        avg_change_pct: avg_change_pct,
        total_collected: total_collected,
        total_paid: total_paid,
        avg_capture_multiple: avg_capture_multiple
      }
    end
  end

  defp sum_contracts(trades) do
    Enum.reduce(trades, 0, fn trade, acc ->
      acc + (Map.get(trade, :num_contracts) || 0)
    end)
  end

  defp group_by_exit_reason(trades) do
    trades
    |> Enum.group_by(&(Map.get(&1, :options_exit_reason) || "unknown"))
    |> Enum.map(fn {reason, group_trades} ->
      {reason, calculate_group_metrics(group_trades)}
    end)
    |> Map.new()
  end

  defp group_by_contract_type(trades) do
    trades
    |> Enum.group_by(&(Map.get(&1, :contract_type) || "unknown"))
    |> Enum.map(fn {type, group_trades} ->
      {type, calculate_group_metrics(group_trades)}
    end)
    |> Map.new()
  end

  defp group_by_expiration_type(trades) do
    trades
    |> Enum.group_by(&categorize_expiration/1)
    |> Enum.map(fn {type, group_trades} ->
      {type, calculate_group_metrics(group_trades)}
    end)
    |> Map.new()
  end

  defp categorize_expiration(trade) do
    entry_time = Map.get(trade, :entry_time)
    expiration = Map.get(trade, :expiration_date)

    cond do
      is_nil(entry_time) or is_nil(expiration) ->
        "unknown"

      true ->
        entry_date = DateTime.to_date(entry_time)
        dte = Date.diff(expiration, entry_date)

        cond do
          dte == 0 -> "0dte"
          dte <= 7 -> "weekly"
          dte <= 30 -> "monthly"
          true -> "leaps"
        end
    end
  end

  defp group_by_strike_distance(trades) do
    trades
    |> Enum.group_by(&categorize_strike_distance/1)
    |> Enum.map(fn {distance, group_trades} ->
      {distance, calculate_group_metrics(group_trades)}
    end)
    |> Map.new()
  end

  defp categorize_strike_distance(trade) do
    strike = Map.get(trade, :strike)
    entry_price = Map.get(trade, :entry_price)
    contract_type = Map.get(trade, :contract_type)

    cond do
      is_nil(strike) or is_nil(entry_price) ->
        "unknown"

      true ->
        strike_d = ensure_decimal(strike)
        entry_d = ensure_decimal(entry_price)

        # Calculate percentage distance from underlying
        distance_pct =
          Decimal.sub(strike_d, entry_d)
          |> Decimal.div(entry_d)
          |> Decimal.mult(@hundred)
          |> Decimal.abs()
          |> Decimal.to_float()

        # Adjust for contract type (OTM is above for calls, below for puts)
        is_otm =
          case contract_type do
            "call" -> Decimal.compare(strike_d, entry_d) == :gt
            "put" -> Decimal.compare(strike_d, entry_d) == :lt
            _ -> false
          end

        cond do
          distance_pct <= 1.0 -> "atm"
          distance_pct <= 3.0 and is_otm -> "1_otm"
          distance_pct <= 5.0 and is_otm -> "2_otm"
          is_otm -> "deep_otm"
          true -> "itm"
        end
    end
  end

  defp calculate_avg_dte(trades) do
    dtes =
      trades
      |> Enum.map(fn trade ->
        entry_time = Map.get(trade, :entry_time)
        expiration = Map.get(trade, :expiration_date)

        if entry_time && expiration do
          entry_date = DateTime.to_date(entry_time)
          Date.diff(expiration, entry_date)
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(dtes) do
      nil
    else
      div(Enum.sum(dtes), length(dtes))
    end
  end

  defp calculate_group_metrics(trades) when length(trades) == 0 do
    %{
      count: 0,
      win_rate: @zero,
      avg_r: nil,
      total_pnl: @zero,
      avg_pnl: nil,
      total_contracts: 0
    }
  end

  defp calculate_group_metrics(trades) do
    winners =
      Enum.count(trades, fn trade ->
        pnl = Map.get(trade, :pnl, @zero) || @zero
        Decimal.compare(pnl, @zero) == :gt
      end)

    pnls = Enum.map(trades, &(Map.get(&1, :pnl) || @zero))
    total_pnl = Enum.reduce(pnls, @zero, &Decimal.add/2)

    r_multiples =
      trades
      |> Enum.map(&Map.get(&1, :r_multiple))
      |> Enum.reject(&is_nil/1)

    avg_r =
      if Enum.empty?(r_multiples) do
        nil
      else
        sum = Enum.reduce(r_multiples, @zero, &Decimal.add/2)
        Decimal.div(sum, Decimal.new(length(r_multiples))) |> Decimal.round(2)
      end

    %{
      count: length(trades),
      win_rate: percentage(winners, length(trades)),
      avg_r: avg_r,
      total_pnl: total_pnl |> Decimal.round(2),
      avg_pnl: Decimal.div(total_pnl, Decimal.new(length(trades))) |> Decimal.round(2),
      total_contracts: sum_contracts(trades)
    }
  end

  defp average([]), do: nil

  defp average(values) do
    values
    |> Enum.reduce(@zero, &Decimal.add/2)
    |> Decimal.div(Decimal.new(length(values)))
    |> Decimal.round(2)
  end

  defp percentage(_count, 0), do: @zero

  defp percentage(count, total) do
    Decimal.div(Decimal.new(count * 100), Decimal.new(total))
    |> Decimal.round(2)
  end

  defp get_decimal(map, key) do
    case Map.get(map, key) do
      nil -> @zero
      %Decimal{} = d -> d
      n when is_number(n) -> Decimal.new(to_string(n))
      s when is_binary(s) -> Decimal.new(s)
    end
  end

  defp ensure_decimal(%Decimal{} = d), do: d
  defp ensure_decimal(n) when is_number(n), do: Decimal.new(to_string(n))
  defp ensure_decimal(s) when is_binary(s), do: Decimal.new(s)
  defp ensure_decimal(_), do: @zero

  defp div_decimal(numerator, denominator)
       when is_integer(numerator) and is_integer(denominator) do
    Decimal.div(Decimal.new(numerator), Decimal.new(denominator)) |> Decimal.round(2)
  end
end
