defmodule Signal.Options.PositionSizer do
  @moduledoc """
  Calculates position size (number of contracts) for options trades.

  Options position sizing differs from equity sizing because:
  - Each contract controls 100 shares
  - Risk is typically the full premium paid (max loss on long options)
  - Position size is in contracts, not shares

  ## Sizing Strategies

  ### Premium-Based (Default)
  Allocates the risk budget directly to premium cost:
  - contracts = risk_amount / (premium × 100)
  - Max loss = premium paid

  ### Delta-Adjusted (Future)
  Adjusts for the option's delta to approximate equity exposure:
  - contracts = risk_amount / (premium × 100 × delta)

  ## Usage

      # Calculate contracts based on risk budget
      {:ok, contracts, cost} = PositionSizer.calculate(
        entry_premium: Decimal.new("5.25"),
        risk_amount: Decimal.new("1000"),
        available_cash: Decimal.new("50000")
      )

      # With custom multiplier (non-standard contracts)
      {:ok, contracts, cost} = PositionSizer.calculate(
        entry_premium: Decimal.new("5.25"),
        risk_amount: Decimal.new("1000"),
        multiplier: 100
      )
  """

  @default_multiplier 100
  @min_contracts 1

  @type sizing_result :: {:ok, pos_integer(), Decimal.t()} | {:error, atom()}

  @doc """
  Calculates the number of contracts to trade based on risk parameters.

  ## Parameters

  Required options:
    * `:entry_premium` - Premium per share at entry
    * `:risk_amount` - Dollar amount willing to risk

  Optional:
    * `:available_cash` - Cash available (defaults to unlimited)
    * `:multiplier` - Contract multiplier (default: 100)
    * `:max_contracts` - Maximum contracts to trade (default: unlimited)
    * `:min_contracts` - Minimum contracts (default: 1)

  ## Returns

    * `{:ok, num_contracts, total_cost}` - Number of contracts and total premium cost
    * `{:error, :insufficient_funds}` - Not enough cash for minimum contracts
    * `{:error, :invalid_premium}` - Premium is zero or negative

  ## Examples

      # Risk $1000, premium $5.25 per share
      # Cost per contract = $5.25 × 100 = $525
      # Contracts = $1000 / $525 = 1 (rounded down)
      {:ok, 1, Decimal.new("525")} = PositionSizer.calculate(
        entry_premium: Decimal.new("5.25"),
        risk_amount: Decimal.new("1000")
      )

      # Risk $2000, premium $3.00 per share
      # Cost per contract = $3.00 × 100 = $300
      # Contracts = $2000 / $300 = 6 (rounded down)
      {:ok, 6, Decimal.new("1800")} = PositionSizer.calculate(
        entry_premium: Decimal.new("3.00"),
        risk_amount: Decimal.new("2000")
      )
  """
  @spec calculate(keyword()) :: sizing_result()
  def calculate(opts) do
    with {:ok, premium} <- get_premium(opts),
         {:ok, risk_amount} <- get_risk_amount(opts),
         :ok <- validate_premium(premium) do
      multiplier = Keyword.get(opts, :multiplier, @default_multiplier)
      available_cash = Keyword.get(opts, :available_cash)
      max_contracts = Keyword.get(opts, :max_contracts)
      min_contracts = Keyword.get(opts, :min_contracts, @min_contracts)

      # Cost per contract
      cost_per_contract = Decimal.mult(premium, Decimal.new(multiplier))

      # Calculate contracts based on risk budget
      contracts_from_risk =
        risk_amount
        |> Decimal.div(cost_per_contract)
        |> Decimal.round(0, :floor)
        |> Decimal.to_integer()

      # Apply constraints
      contracts =
        contracts_from_risk
        |> apply_minimum(min_contracts)
        |> apply_maximum(max_contracts)
        |> apply_cash_constraint(available_cash, cost_per_contract)

      if contracts < min_contracts do
        {:error, :insufficient_funds}
      else
        total_cost = Decimal.mult(cost_per_contract, Decimal.new(contracts))
        {:ok, contracts, total_cost}
      end
    end
  end

  @doc """
  Calculates position size from account equity and risk percentage.

  Convenience function that combines equity-based risk calculation with
  contract sizing.

  ## Parameters

    * `:account_equity` - Current account equity
    * `:risk_percentage` - Percentage of equity to risk (e.g., 0.01 for 1%)
    * `:entry_premium` - Premium per share at entry
    * Other options passed to `calculate/1`

  ## Examples

      # $100,000 account, 1% risk = $1000 risk budget
      {:ok, contracts, cost} = PositionSizer.from_equity(
        account_equity: Decimal.new("100000"),
        risk_percentage: Decimal.new("0.01"),
        entry_premium: Decimal.new("5.00")
      )
  """
  @spec from_equity(keyword()) :: sizing_result()
  def from_equity(opts) do
    with {:ok, equity} <- fetch_required(opts, :account_equity),
         {:ok, risk_pct} <- fetch_required(opts, :risk_percentage) do
      risk_amount = Decimal.mult(equity, risk_pct)

      opts
      |> Keyword.put(:risk_amount, risk_amount)
      |> calculate()
    end
  end

  @doc """
  Estimates the maximum loss for a long options position.

  For long calls/puts, max loss is the premium paid.

  ## Parameters

    * `num_contracts` - Number of contracts
    * `entry_premium` - Premium per share paid
    * `multiplier` - Contract multiplier (default: 100)

  ## Returns

    * Maximum loss as a Decimal
  """
  @spec max_loss(pos_integer(), Decimal.t(), pos_integer()) :: Decimal.t()
  def max_loss(num_contracts, entry_premium, multiplier \\ @default_multiplier) do
    entry_premium
    |> Decimal.mult(Decimal.new(multiplier))
    |> Decimal.mult(Decimal.new(num_contracts))
  end

  @doc """
  Calculates breakeven price for the underlying.

  ## Parameters

    * `strike` - Strike price
    * `premium` - Premium paid per share
    * `contract_type` - :call or :put

  ## Returns

    * Breakeven price as a Decimal

  ## Examples

      # Call with $150 strike, $5.25 premium
      # Breakeven = $155.25
      PositionSizer.breakeven(Decimal.new("150"), Decimal.new("5.25"), :call)

      # Put with $150 strike, $3.50 premium
      # Breakeven = $146.50
      PositionSizer.breakeven(Decimal.new("150"), Decimal.new("3.50"), :put)
  """
  @spec breakeven(Decimal.t(), Decimal.t(), :call | :put) :: Decimal.t()
  def breakeven(strike, premium, :call) do
    Decimal.add(strike, premium)
  end

  def breakeven(strike, premium, :put) do
    Decimal.sub(strike, premium)
  end

  # Private Functions

  defp get_premium(opts) do
    fetch_required(opts, :entry_premium)
  end

  defp get_risk_amount(opts) do
    fetch_required(opts, :risk_amount)
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, ensure_decimal(value)}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp ensure_decimal(%Decimal{} = d), do: d
  defp ensure_decimal(n) when is_number(n), do: Decimal.new(to_string(n))
  defp ensure_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp validate_premium(premium) do
    if Decimal.gt?(premium, Decimal.new(0)) do
      :ok
    else
      {:error, :invalid_premium}
    end
  end

  defp apply_minimum(contracts, min) when contracts < min, do: min
  defp apply_minimum(contracts, _min), do: contracts

  defp apply_maximum(contracts, nil), do: contracts
  defp apply_maximum(contracts, max) when contracts > max, do: max
  defp apply_maximum(contracts, _max), do: contracts

  defp apply_cash_constraint(contracts, nil, _cost_per_contract), do: contracts

  defp apply_cash_constraint(contracts, available_cash, cost_per_contract) do
    max_from_cash =
      available_cash
      |> Decimal.div(cost_per_contract)
      |> Decimal.round(0, :floor)
      |> Decimal.to_integer()

    min(contracts, max_from_cash)
  end
end
