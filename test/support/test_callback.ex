defmodule Signal.TestCallback do
  @moduledoc """
  Test callback module for Alpaca.Stream integration testing.

  Implements the callback behavior and stores received messages in an Agent
  for verification during tests.
  """

  use Agent

  @doc """
  Starts the test callback agent with initial state.

  ## Parameters

    - `initial_state` - Map with :messages key (defaults to empty list)

  ## Returns

    - `{:ok, pid}` - Agent process
  """
  def start_link(initial_state \\ %{messages: [], counters: %{}}) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  @doc """
  Callback function for handling messages from Alpaca.Stream.

  Stores each message in the agent state for later verification.

  ## Parameters

    - `message` - Normalized message map from Alpaca stream
    - `state` - Current callback state

  ## Returns

    - `{:ok, new_state}` - Updated state with message added
  """
  @spec handle_message(map(), map()) :: {:ok, map()}
  def handle_message(message, state) do
    Agent.update(__MODULE__, fn current_state ->
      new_messages = [message | current_state.messages]

      # Update counters by type
      type = message.type
      counters = Map.update(current_state.counters, type, 1, &(&1 + 1))

      %{current_state | messages: new_messages, counters: counters}
    end)

    {:ok, state}
  end

  @doc """
  Gets the current state from the agent.

  ## Returns

    - Map with :messages and :counters keys
  """
  def get_state do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Gets all messages received.

  ## Returns

    - List of message maps
  """
  def get_messages do
    Agent.get(__MODULE__, fn state -> state.messages end)
  end

  @doc """
  Gets message counters by type.

  ## Returns

    - Map of message type to count
  """
  def get_counters do
    Agent.get(__MODULE__, fn state -> state.counters end)
  end

  @doc """
  Resets the state (clears all messages and counters).
  """
  def reset do
    Agent.update(__MODULE__, fn _state -> %{messages: [], counters: %{}} end)
  end

  @doc """
  Stops the agent.
  """
  def stop do
    if Process.whereis(__MODULE__) do
      Agent.stop(__MODULE__)
    end
  end
end
