defmodule Signal.SignalGenerator do
  @moduledoc """
  Generates trade signals from setups and manages their lifecycle.

  The SignalGenerator takes validated setups, analyzes them for confluence,
  and generates trade signals that are stored in the database and broadcast
  via PubSub for real-time consumption.

  ## Signal Lifecycle

  1. **Generation**: Setup detected → Confluence analyzed → Signal created
  2. **Active**: Signal is valid and can be taken
  3. **Filled**: Trade was entered at signal price
  4. **Expired**: Time expired without being taken
  5. **Invalidated**: Market conditions changed (e.g., level reclaimed)

  ## Usage

      # Generate a signal from a setup
      {:ok, signal} = SignalGenerator.generate(setup, context)

      # Update signal status
      {:ok, signal} = SignalGenerator.fill(signal, fill_price)
      {:ok, signal} = SignalGenerator.expire(signal)
      {:ok, signal} = SignalGenerator.invalidate(signal)

      # Query signals
      signals = SignalGenerator.get_active_signals("AAPL")
      signals = SignalGenerator.get_signals_by_grade(:A)
  """

  alias Signal.Repo
  alias Signal.Strategies.Setup
  alias Signal.Signals.TradeSignal
  alias Signal.ConfluenceAnalyzer

  import Ecto.Query

  @default_expiry_minutes 30
  @min_grade :C
  @rate_limit_minutes 5
  @max_signals_per_day 2

  @doc """
  Generates a trade signal from a setup.

  Analyzes the setup for confluence, assigns a quality grade, and if it meets
  minimum requirements, creates and stores the signal.

  ## Parameters

    * `setup` - The validated trade setup
    * `context` - Additional context for confluence analysis
    * `opts` - Options
      * `:min_grade` - Minimum quality grade to generate signal (default: :C)
      * `:expiry_minutes` - Minutes until signal expires (default: 30)
      * `:broadcast` - Whether to broadcast the signal (default: true)
      * `:skip_rate_limit` - Skip rate limiting checks (default: false)

  ## Returns

    * `{:ok, signal}` - Signal generated and stored
    * `{:error, :below_minimum_grade}` - Setup didn't meet quality requirements
    * `{:error, :rate_limited}` - Signal generated too recently for this symbol
    * `{:error, :daily_limit_reached}` - Max signals per day reached for this symbol
    * `{:error, :duplicate_signal}` - Active signal already exists for this setup
    * `{:error, reason}` - Other failure reason
  """
  @spec generate(Setup.t(), map(), keyword()) ::
          {:ok, TradeSignal.t()} | {:error, atom()}
  def generate(%Setup{} = setup, context \\ %{}, opts \\ []) do
    min_grade = Keyword.get(opts, :min_grade, @min_grade)
    expiry_minutes = Keyword.get(opts, :expiry_minutes, @default_expiry_minutes)
    broadcast = Keyword.get(opts, :broadcast, true)
    skip_rate_limit = Keyword.get(opts, :skip_rate_limit, false)

    with :ok <- check_rate_limits(setup, skip_rate_limit),
         :ok <- check_duplicate_signal(setup),
         {:ok, analysis} <- ConfluenceAnalyzer.analyze(setup, context),
         true <- ConfluenceAnalyzer.meets_minimum?(analysis, min_grade),
         {:ok, signal} <- create_signal(setup, analysis, expiry_minutes),
         {:ok, stored_signal} <- store_signal(signal) do
      if broadcast do
        broadcast_signal(stored_signal, :generated)
      end

      {:ok, stored_signal}
    else
      false ->
        {:error, :below_minimum_grade}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a signal can be generated based on rate limits.

  Rate limits:
  - Max 1 signal per symbol per 5 minutes
  - Max 2 signals per symbol per day

  ## Parameters

    * `symbol` - The trading symbol
    * `skip` - Whether to skip rate limit checks

  ## Returns

    * `:ok` - Rate limits not exceeded
    * `{:error, :rate_limited}` - Signal generated too recently
    * `{:error, :daily_limit_reached}` - Daily limit exceeded
  """
  @spec check_rate_limits(Setup.t() | String.t(), boolean()) ::
          :ok | {:error, :rate_limited | :daily_limit_reached}
  def check_rate_limits(_setup, true), do: :ok

  def check_rate_limits(%Setup{symbol: symbol}, false), do: check_rate_limits(symbol, false)

  def check_rate_limits(symbol, false) when is_binary(symbol) do
    cond do
      recent_signal_exists?(symbol) ->
        {:error, :rate_limited}

      daily_limit_reached?(symbol) ->
        {:error, :daily_limit_reached}

      true ->
        :ok
    end
  end

  @doc """
  Checks if a signal was generated for this symbol within the rate limit window.

  ## Parameters

    * `symbol` - The trading symbol

  ## Returns

  Boolean indicating if a recent signal exists.
  """
  @spec recent_signal_exists?(String.t()) :: boolean()
  def recent_signal_exists?(symbol) do
    cutoff = DateTime.add(DateTime.utc_now(), -@rate_limit_minutes * 60, :second)

    TradeSignal
    |> where([s], s.symbol == ^symbol)
    |> where([s], s.generated_at > ^cutoff)
    |> Repo.exists?()
  end

  @doc """
  Checks if the daily signal limit has been reached for a symbol.

  ## Parameters

    * `symbol` - The trading symbol

  ## Returns

  Boolean indicating if daily limit is reached.
  """
  @spec daily_limit_reached?(String.t()) :: boolean()
  def daily_limit_reached?(symbol) do
    # Get start of today in ET (trading day)
    today_start = get_trading_day_start()

    count =
      TradeSignal
      |> where([s], s.symbol == ^symbol)
      |> where([s], s.generated_at >= ^today_start)
      |> Repo.aggregate(:count, :id)

    count >= @max_signals_per_day
  end

  @doc """
  Checks if an active signal already exists for this setup.

  A duplicate is defined as an active signal with the same symbol, strategy,
  direction, and level_type.

  ## Parameters

    * `setup` - The setup to check

  ## Returns

    * `:ok` - No duplicate exists
    * `{:error, :duplicate_signal}` - Active duplicate exists
  """
  @spec check_duplicate_signal(Setup.t()) :: :ok | {:error, :duplicate_signal}
  def check_duplicate_signal(%Setup{} = setup) do
    strategy = Atom.to_string(setup.strategy)
    direction = Atom.to_string(setup.direction)
    level_type = setup.level_type && Atom.to_string(setup.level_type)

    query =
      TradeSignal
      |> where([s], s.symbol == ^setup.symbol)
      |> where([s], s.strategy == ^strategy)
      |> where([s], s.direction == ^direction)
      |> where([s], s.status == "active")
      |> where([s], s.expires_at > ^DateTime.utc_now())

    query =
      if level_type do
        where(query, [s], s.level_type == ^level_type)
      else
        query
      end

    if Repo.exists?(query) do
      {:error, :duplicate_signal}
    else
      :ok
    end
  end

  @doc """
  Marks a signal as filled.

  ## Parameters

    * `signal` - The signal to mark as filled
    * `fill_price` - The actual fill price (optional, defaults to entry_price)

  ## Returns

    * `{:ok, updated_signal}` - Signal updated
    * `{:error, reason}` - Update failed
  """
  @spec fill(TradeSignal.t(), Decimal.t() | nil) ::
          {:ok, TradeSignal.t()} | {:error, atom()}
  def fill(%TradeSignal{} = signal, fill_price \\ nil) do
    attrs = %{
      status: "filled",
      filled_at: DateTime.utc_now()
    }

    # Use provided fill price or entry price
    attrs =
      if fill_price do
        Map.put(attrs, :exit_price, fill_price)
      else
        attrs
      end

    case update_signal(signal, attrs) do
      {:ok, updated} ->
        broadcast_signal(updated, :filled)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Marks a signal as expired.

  ## Parameters

    * `signal` - The signal to expire

  ## Returns

    * `{:ok, updated_signal}` - Signal updated
    * `{:error, reason}` - Update failed
  """
  @spec expire(TradeSignal.t()) :: {:ok, TradeSignal.t()} | {:error, atom()}
  def expire(%TradeSignal{} = signal) do
    case update_signal(signal, %{status: "expired"}) do
      {:ok, updated} ->
        broadcast_signal(updated, :expired)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Marks a signal as invalidated.

  ## Parameters

    * `signal` - The signal to invalidate
    * `reason` - Optional reason for invalidation

  ## Returns

    * `{:ok, updated_signal}` - Signal updated
    * `{:error, reason}` - Update failed
  """
  @spec invalidate(TradeSignal.t(), String.t() | nil) ::
          {:ok, TradeSignal.t()} | {:error, atom()}
  def invalidate(%TradeSignal{} = signal, _reason \\ nil) do
    case update_signal(signal, %{status: "invalidated"}) do
      {:ok, updated} ->
        broadcast_signal(updated, :invalidated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Gets all active signals for a symbol.

  ## Parameters

    * `symbol` - The trading symbol

  ## Returns

  List of active signals.
  """
  @spec get_active_signals(String.t()) :: list(TradeSignal.t())
  def get_active_signals(symbol) do
    TradeSignal
    |> where([s], s.symbol == ^symbol and s.status == "active")
    |> where([s], s.expires_at > ^DateTime.utc_now())
    |> order_by([s], desc: s.confluence_score)
    |> Repo.all()
  end

  @doc """
  Gets all active signals across all symbols.

  ## Returns

  List of active signals.
  """
  @spec get_all_active_signals() :: list(TradeSignal.t())
  def get_all_active_signals do
    TradeSignal
    |> where([s], s.status == "active")
    |> where([s], s.expires_at > ^DateTime.utc_now())
    |> order_by([s], desc: s.confluence_score, desc: s.generated_at)
    |> Repo.all()
  end

  @doc """
  Gets signals by quality grade.

  ## Parameters

    * `grade` - The quality grade (:A, :B, :C, :D, :F)
    * `opts` - Options
      * `:status` - Filter by status (default: all)
      * `:limit` - Maximum number of results

  ## Returns

  List of signals matching the grade.
  """
  @spec get_signals_by_grade(atom(), keyword()) :: list(TradeSignal.t())
  def get_signals_by_grade(grade, opts \\ []) do
    grade_str = Atom.to_string(grade)
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 100)

    query =
      TradeSignal
      |> where([s], s.quality_grade == ^grade_str)
      |> order_by([s], desc: s.generated_at)
      |> limit(^limit)

    query =
      if status do
        status_str = if is_atom(status), do: Atom.to_string(status), else: status
        where(query, [s], s.status == ^status_str)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets recent signals for a symbol.

  ## Parameters

    * `symbol` - The trading symbol
    * `opts` - Options
      * `:limit` - Maximum number of results (default: 20)
      * `:since` - Only signals since this datetime

  ## Returns

  List of recent signals.
  """
  @spec get_recent_signals(String.t(), keyword()) :: list(TradeSignal.t())
  def get_recent_signals(symbol, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    since = Keyword.get(opts, :since)

    query =
      TradeSignal
      |> where([s], s.symbol == ^symbol)
      |> order_by([s], desc: s.generated_at)
      |> limit(^limit)

    query =
      if since do
        where(query, [s], s.generated_at >= ^since)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Expires all signals that have passed their expiry time.

  ## Returns

    * `{:ok, count}` - Number of signals expired
  """
  @spec expire_old_signals() :: {:ok, integer()}
  def expire_old_signals do
    now = DateTime.utc_now()

    {count, _} =
      TradeSignal
      |> where([s], s.status == "active" and s.expires_at < ^now)
      |> Repo.update_all(set: [status: "expired", updated_at: now])

    {:ok, count}
  end

  @doc """
  Checks if a signal should be invalidated based on current price.

  For long signals: invalidate if price closes below stop loss
  For short signals: invalidate if price closes below entry (level reclaimed)

  ## Parameters

    * `signal` - The signal to check
    * `current_price` - Current market price

  ## Returns

  Boolean indicating if signal should be invalidated.
  """
  @spec should_invalidate?(TradeSignal.t(), Decimal.t()) :: boolean()
  def should_invalidate?(%TradeSignal{direction: "long"} = signal, current_price) do
    Decimal.compare(current_price, signal.stop_loss) == :lt
  end

  def should_invalidate?(%TradeSignal{direction: "short"} = signal, current_price) do
    Decimal.compare(current_price, signal.stop_loss) == :gt
  end

  # Private Functions

  defp create_signal(%Setup{} = setup, analysis, expiry_minutes) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, expiry_minutes * 60, :second)

    signal_attrs = %{
      symbol: setup.symbol,
      strategy: Atom.to_string(setup.strategy),
      direction: Atom.to_string(setup.direction),
      entry_price: setup.entry_price,
      stop_loss: setup.stop_loss,
      take_profit: setup.take_profit,
      risk_reward: setup.risk_reward,
      confluence_score: analysis.total_score,
      quality_grade: Atom.to_string(analysis.grade),
      confluence_factors: stringify_factors(analysis.factors),
      status: "active",
      generated_at: now,
      expires_at: expires_at,
      level_type: setup.level_type && Atom.to_string(setup.level_type),
      level_price: setup.level_price,
      retest_bar_time: setup.retest_bar && setup.retest_bar.bar_time,
      break_bar_time: setup.break_bar && setup.break_bar.bar_time
    }

    {:ok, signal_attrs}
  end

  defp stringify_factors(factors) do
    factors
    |> Enum.map(fn {k, v} ->
      {Atom.to_string(k), stringify_factor(v)}
    end)
    |> Enum.into(%{})
  end

  defp stringify_factor(%{score: score, max_score: max, present: present, details: details}) do
    %{
      "score" => score,
      "max_score" => max,
      "present" => present,
      "details" => details
    }
  end

  defp store_signal(signal_attrs) do
    %TradeSignal{}
    |> TradeSignal.changeset(signal_attrs)
    |> Repo.insert()
  end

  defp update_signal(%TradeSignal{} = signal, attrs) do
    signal
    |> TradeSignal.status_changeset(attrs)
    |> Repo.update()
  end

  defp broadcast_signal(%TradeSignal{} = signal, event_type) do
    # Broadcast to symbol-specific topic
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "signals:#{signal.symbol}",
      {:"signal_#{event_type}", signal}
    )

    # Broadcast to global signals topic
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "signals:all",
      {:"signal_#{event_type}", signal}
    )

    :ok
  end

  # Gets the start of the current trading day (4:00 AM ET)
  # Trading day starts at 4 AM ET with premarket
  defp get_trading_day_start do
    now = DateTime.utc_now()

    case DateTime.shift_zone(now, "America/New_York") do
      {:ok, et_now} ->
        # If before 4 AM ET, use previous day's 4 AM
        et_date =
          if et_now.hour < 4 do
            Date.add(DateTime.to_date(et_now), -1)
          else
            DateTime.to_date(et_now)
          end

        # Create 4 AM ET on that date
        {:ok, naive} = NaiveDateTime.new(et_date, ~T[04:00:00])
        {:ok, et_start} = DateTime.from_naive(naive, "America/New_York")
        DateTime.shift_zone!(et_start, "Etc/UTC")

      {:error, _} ->
        # Fallback: use midnight UTC if timezone conversion fails
        now
        |> DateTime.to_date()
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    end
  end
end
