defmodule Signal.Analytics do
  @moduledoc """
  Comprehensive analytics for backtesting results.

  This module provides a unified interface for calculating and persisting
  all performance analytics from a backtest run.

  ## Usage

      # After a backtest completes
      {:ok, analytics} = Analytics.analyze_backtest(backtest_result)

      # Access individual metrics
      analytics.trade_metrics.win_rate
      analytics.drawdown.max_drawdown_pct
      analytics.equity_curve.sharpe_ratio

      # Persist results
      {:ok, stored_result} = Analytics.persist_results(run_id, analytics)

      # Get summary for display
      summary = Analytics.summary(analytics)
  """

  alias Signal.Analytics.TradeMetrics
  alias Signal.Analytics.Drawdown
  alias Signal.Analytics.EquityCurve
  alias Signal.Analytics.TimeAnalysis
  alias Signal.Analytics.SignalAnalysis
  alias Signal.Analytics.BacktestResult
  alias Signal.Repo

  require Logger

  defstruct [
    :trade_metrics,
    :drawdown,
    :equity_curve,
    :time_analysis,
    :signal_analysis,
    :summary
  ]

  @type t :: %__MODULE__{
          trade_metrics: TradeMetrics.t(),
          drawdown: Drawdown.t(),
          equity_curve: EquityCurve.t(),
          time_analysis: TimeAnalysis.t(),
          signal_analysis: SignalAnalysis.t(),
          summary: map()
        }

  @doc """
  Analyzes a complete backtest result.

  ## Parameters

    * `backtest_result` - Map with:
      * `:closed_trades` - List of closed trade maps
      * `:equity_curve` - List of `{DateTime.t(), Decimal.t()}` tuples
      * `:initial_capital` - Starting capital (optional, will try to infer)

    * `opts` - Options:
      * `:initial_capital` - Override initial capital
      * `:risk_free_rate` - Risk-free rate for Sharpe calculation (default: 0)

  ## Returns

    * `{:ok, %Analytics{}}` - Full analytics calculated
    * `{:error, reason}` - Calculation failed
  """
  @spec analyze_backtest(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def analyze_backtest(backtest_result, opts \\ []) do
    trades = Map.get(backtest_result, :closed_trades, [])
    equity_curve = Map.get(backtest_result, :equity_curve, [])

    initial_capital =
      Keyword.get(opts, :initial_capital) ||
        Map.get(backtest_result, :initial_capital) ||
        infer_initial_capital(equity_curve)

    risk_free_rate = Keyword.get(opts, :risk_free_rate, Decimal.new(0))

    with {:ok, trade_metrics} <- TradeMetrics.calculate(trades),
         {:ok, drawdown} <- Drawdown.calculate(equity_curve, trades, initial_capital),
         {:ok, equity_analysis} <-
           EquityCurve.analyze(equity_curve, initial_capital,
             risk_free_rate: risk_free_rate,
             max_drawdown: drawdown.max_drawdown_pct
           ),
         {:ok, time_analysis} <- TimeAnalysis.calculate(trades),
         {:ok, signal_analysis} <- SignalAnalysis.calculate(trades) do
      analytics = %__MODULE__{
        trade_metrics: trade_metrics,
        drawdown: drawdown,
        equity_curve: equity_analysis,
        time_analysis: time_analysis,
        signal_analysis: signal_analysis,
        summary:
          build_summary(trade_metrics, drawdown, equity_analysis, time_analysis, signal_analysis)
      }

      {:ok, analytics}
    end
  end

  @doc """
  Persists analytics results to the database.

  ## Parameters

    * `backtest_run_id` - UUID of the backtest run
    * `analytics` - `%Analytics{}` struct from `analyze_backtest/2`

  ## Returns

    * `{:ok, %BacktestResult{}}` - Results persisted
    * `{:error, changeset}` - Persistence failed
  """
  @spec persist_results(String.t(), t()) :: {:ok, BacktestResult.t()} | {:error, term()}
  def persist_results(backtest_run_id, %__MODULE__{} = analytics) do
    attrs = BacktestResult.from_analytics(backtest_run_id, Map.from_struct(analytics))

    %BacktestResult{}
    |> BacktestResult.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Loads persisted analytics for a backtest run.

  ## Returns

    * `{:ok, %BacktestResult{}}` - Results found
    * `{:error, :not_found}` - No results for this run
  """
  @spec load_results(String.t()) :: {:ok, BacktestResult.t()} | {:error, :not_found}
  def load_results(backtest_run_id) do
    case Repo.get_by(BacktestResult, backtest_run_id: backtest_run_id) do
      nil -> {:error, :not_found}
      result -> {:ok, result}
    end
  end

  @doc """
  Returns a condensed summary of key metrics.

  Useful for display and quick comparison between backtests.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{summary: summary}), do: summary

  @doc """
  Generates a formatted text report of analytics.
  """
  @spec to_report(t()) :: String.t()
  def to_report(%__MODULE__{} = analytics) do
    tm = analytics.trade_metrics
    dd = analytics.drawdown
    ec = analytics.equity_curve

    """
    ══════════════════════════════════════════════════════════════════
    BACKTEST PERFORMANCE REPORT
    ══════════════════════════════════════════════════════════════════

    TRADE METRICS
    ─────────────────────────────────────────────────────────────────
    Total Trades:        #{tm.total_trades}
    Winners:             #{tm.winners} (#{format_decimal(tm.win_rate)}%)
    Losers:              #{tm.losers} (#{format_decimal(tm.loss_rate)}%)

    Net Profit:          $#{format_decimal(tm.net_profit)}
    Profit Factor:       #{format_decimal(tm.profit_factor) || "N/A"}
    Expectancy:          $#{format_decimal(tm.expectancy)}/trade

    Avg Win:             $#{format_decimal(tm.avg_win)}
    Avg Loss:            $#{format_decimal(tm.avg_loss)}
    Avg R-Multiple:      #{format_decimal(tm.avg_r_multiple) || "N/A"}R

    Avg Hold Time:       #{tm.avg_hold_time_minutes || 0} minutes

    DRAWDOWN ANALYSIS
    ─────────────────────────────────────────────────────────────────
    Max Drawdown:        #{format_decimal(dd.max_drawdown_pct)}% ($#{format_decimal(dd.max_drawdown_dollars)})
    Max DD Duration:     #{dd.max_drawdown_duration_days || 0} days
    Recovery Factor:     #{format_decimal(dd.recovery_factor) || "N/A"}

    Max Consecutive Wins:   #{dd.max_consecutive_wins}
    Max Consecutive Losses: #{dd.max_consecutive_losses}

    RISK-ADJUSTED RETURNS
    ─────────────────────────────────────────────────────────────────
    Total Return:        #{format_decimal(ec.total_return_pct)}%
    Annualized Return:   #{format_decimal(ec.annualized_return_pct) || "N/A"}%
    Volatility:          #{format_decimal(ec.volatility) || "N/A"}%

    Sharpe Ratio:        #{format_decimal(ec.sharpe_ratio) || "N/A"}
    Sortino Ratio:       #{format_decimal(ec.sortino_ratio) || "N/A"}
    Calmar Ratio:        #{format_decimal(ec.calmar_ratio) || "N/A"}

    TIME ANALYSIS
    ─────────────────────────────────────────────────────────────────
    Best Time Slot:      #{analytics.time_analysis.best_time_slot || "N/A"}
    Worst Time Slot:     #{analytics.time_analysis.worst_time_slot || "N/A"}
    Best Day:            #{analytics.time_analysis.best_weekday || "N/A"}
    Worst Day:           #{analytics.time_analysis.worst_weekday || "N/A"}

    SIGNAL ANALYSIS
    ─────────────────────────────────────────────────────────────────
    Best Grade:          #{analytics.signal_analysis.best_grade || "N/A"}
    Worst Grade:         #{analytics.signal_analysis.worst_grade || "N/A"}
    Best Strategy:       #{analytics.signal_analysis.best_strategy || "N/A"}
    Best Symbol:         #{analytics.signal_analysis.best_symbol || "N/A"}

    ══════════════════════════════════════════════════════════════════
    """
  end

  # Private Functions

  defp infer_initial_capital([]), do: Decimal.new("100000")

  defp infer_initial_capital(equity_curve) do
    # Use the first equity point as initial capital
    sorted =
      equity_curve
      |> Enum.sort_by(fn {time, _} -> DateTime.to_unix(time) end)

    case sorted do
      [{_, equity} | _] -> equity
      _ -> Decimal.new("100000")
    end
  end

  defp build_summary(trade_metrics, drawdown, equity_curve, time_analysis, signal_analysis) do
    %{
      # Key metrics
      total_trades: trade_metrics.total_trades,
      win_rate: trade_metrics.win_rate,
      profit_factor: trade_metrics.profit_factor,
      net_profit: trade_metrics.net_profit,
      expectancy: trade_metrics.expectancy,

      # Risk metrics
      max_drawdown_pct: drawdown.max_drawdown_pct,
      sharpe_ratio: equity_curve.sharpe_ratio,
      sortino_ratio: equity_curve.sortino_ratio,

      # Return metrics
      total_return_pct: equity_curve.total_return_pct,
      annualized_return_pct: equity_curve.annualized_return_pct,

      # Best performers
      best_time_slot: time_analysis.best_time_slot,
      best_strategy: signal_analysis.best_strategy,
      best_symbol: signal_analysis.best_symbol
    }
  end

  defp format_decimal(nil), do: nil

  defp format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(2)
    |> Decimal.to_string()
  end

  defp format_decimal(other), do: to_string(other)
end
