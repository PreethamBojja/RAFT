defmodule Rabia.Command do
  @moduledoc """
  Defines commands for the linearizable register
  implemented in this lab using Rabia.
  """
  alias __MODULE__
  @enforce_keys [:client_seq, :operation]
  defstruct(
    # Used by clients to determine request.
    client_seq: nil,
    # Operation being performed.
    operation: nil,
    args: nil
  )

  @doc """

  """
  @spec nop(non_neg_integer()) :: %Command{
          client_seq: non_neg_integer(),
          operation: :nop,
          args: nil
        }
  def nop(seq) do
    %Command{
      client_seq: seq,
      operation: :nop,
      args: nil
    }
  end

  @spec get(non_neg_integer()) :: %Command{
          client_seq: non_neg_integer(),
          operation: :get,
          args: nil
        }
  def get(seq) do
    %Command{
      client_seq: seq,
      operation: :get,
      args: nil
    }
  end

  @spec inc(non_neg_integer(), integer()) :: %Command{
          client_seq: non_neg_integer(),
          operation: :inc,
          args: integer()
        }
  def inc(seq, by) do
    %Command{
      client_seq: seq,
      operation: :inc,
      args: by
    }
  end
end

defmodule Rabia.CommandResponse do
  @moduledoc """
  Responses sent by the server to clients.
  """
  alias __MODULE__
  @enforce_keys [:client_seq, :return]
  defstruct(
    client_seq: 0,
    return: nil
  )

  @doc """
  Response for a nop request.
  """
  @spec nop_response(non_neg_integer()) ::
          %CommandResponse{client_seq: non_neg_integer(), return: :ok}
  def nop_response(seq) do
    %CommandResponse{client_seq: seq, return: :ok}
  end

  @doc """
  Response for an inc request.
  """
  @spec inc_response(non_neg_integer()) ::
          %Rabia.CommandResponse{
            client_seq: non_neg_integer(),
            return: :ok
          }
  def inc_response(seq) do
    %CommandResponse{client_seq: seq, return: :ok}
  end

  @doc """
  Responds for a get request.
  """
  @spec get_response(non_neg_integer(), integer()) ::
          %Rabia.CommandResponse{client_seq: non_neg_integer(), return: integer()}
  def get_response(seq, val) do
    %CommandResponse{client_seq: seq, return: val}
  end
end

defmodule Rabia.Timestamp do
  @moduledoc """
  Commands in a Rabia server's priority queue
  are ordered by timestamps defined by this module.
  """
  alias __MODULE__
  @enforce_keys [:node_id, :idx]
  defstruct(
    idx: nil,
    node_id: nil
  )

  @doc """
  Create a timestamp for a client command.
  """
  @spec new(atom(), non_neg_integer()) ::
          %Rabia.Timestamp{idx: non_neg_integer(), node_id: atom()}
  def new(node_id, idx) do
    %Timestamp{node_id: node_id, idx: idx}
  end
end

defmodule Rabia.TimestampedCommand do
  @moduledoc """
  A timestamp and command tuple, used in the priority queue
  and the rest of the protocol.
  """
  @enforce_keys [:timestamp, :command]
  defstruct(
    timestamp: nil,
    command: nil
  )
end

defmodule Rabia.StateMessage do
  @moduledoc """
  State messages for Rabia.
  """
  alias __MODULE__
  @enforce_keys [:round, :state]
  defstruct(
    round: 0,
    state: nil,
    command: nil
  )

  @doc """
  Create a new state message for `round`. The `command` value contains
  a command iff `state` is not `:bot`.
  """
  @spec new(non_neg_integer(), any(), any()) :: %Rabia.StateMessage{
          command: any(),
          round: non_neg_integer(),
          state: any()
        }
  def new(round, state, command \\ nil) do
    %StateMessage{round: round, state: state, command: command}
  end
end

defmodule Rabia.VoteMessage do
  @moduledoc """
  A Rabia vote message.
  """
  alias __MODULE__
  @enforce_keys [:round, :vote]
  defstruct(
    round: 0,
    vote: nil,
    command: nil
  )

  @doc """
  Create a Rabia vote message for `round`. The `command` should be
  set to non-nil whenever voting for something other than `?`.
  """
  @spec new(non_neg_integer(), :cmd | :qmark, any()) ::
          %Rabia.VoteMessage{command: any(), round: non_neg_integer(), vote: :cmd | :qmark}
  def new(round, vote, command \\ nil) do
    %VoteMessage{round: round, vote: vote, command: command}
  end
end

defmodule Rabia.ProtocolMessage do
  @moduledoc """
  Used to wrap all protocol messages between Rabia servers.
  """
  import Emulation, only: [whoami: 0]
  alias Rabia.TimestampedCommand
  alias __MODULE__
  @enforce_keys [:type, :node, :contents]
  defstruct(
    # Message type.
    type: nil,
    # Sender of this message.
    node: nil,
    # The log slot whose Rabia state machine
    # this message targets.
    log_idx: nil,
    # The actual contents of the message.
    contents: nil
  )

  # Message types we use.
  _valid_types = [:replicate, :proposal, :state, :vote, :decided]

  @doc """
  A message to replicate client requests to all servers so that they
  can add it to their PQ and propose.
  """
  @spec replicate_propsal(
          %Rabia.Timestamp{},
          %Rabia.Command{}
        ) :: %ProtocolMessage{
          type: :replicate,
          node: atom() | pid(),
          contents: %TimestampedCommand{},
          log_idx: nil
        }
  def replicate_propsal(ts, command) do
    %ProtocolMessage{
      type: :replicate,
      node: whoami(),
      contents: %TimestampedCommand{timestamp: ts, command: command}
    }
  end

  @doc """
  Create a Rabia proposal message given a log index (`seq`) and
  timestamped comamdn (`ts_cmd`).
  """
  @spec proposal_message(non_neg_integer(), %TimestampedCommand{}) ::
          %Rabia.ProtocolMessage{
            contents: %TimestampedCommand{},
            log_idx: non_neg_integer(),
            node: atom() | pid(),
            type: :proposal
          }
  def proposal_message(seq, ts_cmd) do
    %ProtocolMessage{
      type: :proposal,
      node: whoami(),
      log_idx: seq,
      contents: ts_cmd
    }
  end

  @doc """
  Create a Rabia state message.
  """
  @spec state_message(non_neg_integer(), non_neg_integer(), any()) :: %Rabia.ProtocolMessage{
          contents: %Rabia.StateMessage{command: any(), round: non_neg_integer(), state: any()},
          log_idx: any(),
          node: atom() | pid(),
          type: :state
        }
  def state_message(seq, round, state, command \\ nil) do
    %ProtocolMessage{
      type: :state,
      node: whoami(),
      log_idx: seq,
      contents: Rabia.StateMessage.new(round, state, command)
    }
  end

  @doc """
  Create a Rabia vote message.
  """
  @spec vote_message(non_neg_integer(), non_neg_integer(), any()) :: %Rabia.ProtocolMessage{
          contents: %Rabia.VoteMessage{command: any(), round: any(), vote: any()},
          log_idx: any(),
          node: atom() | pid(),
          type: :vote
        }
  def vote_message(seq, round, vote, command \\ nil) do
    %ProtocolMessage{
      type: :vote,
      node: whoami(),
      log_idx: seq,
      contents: Rabia.VoteMessage.new(round, vote, command)
    }
  end

  @doc """
  We use `decided` messages to allow Rabia servers to notify each
  other of cases where a log index has already been decided.
  """
  @spec decided(any(), any()) :: %Rabia.ProtocolMessage{
          contents: any(),
          log_idx: any(),
          node: atom() | pid(),
          type: :decided
        }
  def decided(idx, command) do
    %ProtocolMessage{
      type: :decided,
      log_idx: idx,
      node: whoami(),
      contents: command
    }
  end
end
