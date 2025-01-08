defmodule Rabia do
  import Emulation, only: [send: 2, whoami: 0]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  alias Rabia.ProtocolMessage
  alias __MODULE__
  require Fuzzers
  # This allows you to use Elixir's loggers. Remember `config/config.exs` is
  # set up so everything before :info is purged at compile time.
  require Logger

  @p1_stage :phase1
  @p2s_stage :phase2state
  @p2v_stage :phase2vote
  @decided :decided

  # Utility function
  defp check_assumption(pred, explanation) do
    if not pred do
      raise("[#{whoami()}] #{explanation}")
    end
  end

  @enforce_keys [:replicas, :quorum_size]
  defstruct(
    # The actual counter.
    counter: 0,
    # Configuration: other servers
    replicas: [],
    # Configuration: quorum size.
    quorum_size: 0,
    # Number of client commands received.
    cmd_seq: 1,
    # Pending requests from clients
    pending_requests: %{},
    # Priority queue
    propose_queue: Prioqueue.new(),
    # Next slot index
    seq: 1,
    # State machine
    # Map from log idx -> stage
    mvc_stage: %{},
    # A map from log idx -> proposal made by this node
    weak_mvc_my_proposal: %{},
    # Phase 1 state
    # A map from log idx -> proposals.
    weak_mvc_proposals: %{},
    # A map from log idx -> chosen proposal.
    weak_mvc_chosen_command: %{},
    # Phase 2 state
    # A map from log idx -> Ben-Or round.
    weak_mvc_round: %{},
    # A map from log idx -> queued state messages received
    # before Phase 1 has finished.
    queued_state_messages: %{},
    # A map from log idx -> state messages in the current round.
    weak_mvc_state_messages: %{},
    # A map from log idx -> non-bot command in the current round.
    weak_mvc_state_cmd: %{},
    # A map from log idx -> vote cast by the node for this round.
    weak_mvc_vote: %{},
    # A map from log idx -> queued vote messages, used
    # to implement waiting for state messages before moving on.
    queued_vote_messages: %{},
    # A map from log idx -> map of votes received this round.
    weak_mvc_votes: %{},
    # A map from log idx -> map of vote command received this round.
    weak_mvc_vote_cmds: %{},
    # A map from log idx -> Ben-Or decision
    cmd_log: %{},
    # Counter to keep track index of last executed log command
    last_exec_seq: 0,
    # A map from log idx -> pending decided message to execute if any
    pending_decided_messages: %{}
  )

  @doc """
  Create a new configuration given a list of nodes.
  """
  @spec new_configuration(list()) :: %Rabia{
          cmd_log: %{},
          cmd_seq: 1,
          mvc_stage: %{},
          pending_requests: %{},
          propose_queue: %Prioqueue.Implementations.SkewHeap{
            cmp_fun: (any(), any() -> any()),
            contents: nil
          },
          queued_state_messages: %{},
          queued_vote_messages: %{},
          quorum_size: integer(),
          replicas: list(),
          seq: 1,
          weak_mvc_chosen_command: %{},
          weak_mvc_my_proposal: %{},
          weak_mvc_proposals: %{},
          weak_mvc_round: %{},
          weak_mvc_state_cmd: %{},
          weak_mvc_state_messages: %{},
          weak_mvc_vote: %{},
          weak_mvc_vote_cmds: %{},
          weak_mvc_votes: %{}
        }
  def new_configuration(replicas) do
    %Rabia{replicas: replicas, quorum_size: floor(length(replicas) / 2) + 1}
  end

  # Broadcast a message to all nodes in the configuration (including
  # the sender.)
  @spec bcast(%Rabia{:replicas => any()}, any()) :: list()
  defp bcast(%Rabia{replicas: replicas}, msg) do
    replicas
    |> Enum.map(fn pid -> send(pid, msg) end)
  end

  # Look at the priority queue to pick the next
  # item the node should propose.
  @spec propose_next_command(%Rabia{
          :propose_queue => any(),
          :replicas => any(),
          :seq => non_neg_integer(),
          :weak_mvc_round => map()
        }) :: %Rabia{
          :propose_queue => any(),
          :replicas => any(),
          :seq => pos_integer(),
          :weak_mvc_round => map()
        }
  defp propose_next_command(
         state = %Rabia{
           propose_queue: q,
           seq: s,
           weak_mvc_my_proposal: props
         }
       ) do
    # Should only be called when propose_queue has elements.
    {c, q} = Prioqueue.extract_min!(q)
    proposal = Rabia.ProtocolMessage.proposal_message(s, c)
    bcast(state, proposal)
    Logger.warning("#{whoami()} proposing #{inspect(c)} for #{s}")

    %{state | propose_queue: q, seq: s + 1, weak_mvc_my_proposal: Map.put(props, s, c)}
  end

  # Phase 1: Proposal
  # Called by `run` to process proposal messages as a part of Phase 1 of
  # Weak MVC.
  defp process_proposal(
         state = %Rabia{mvc_stage: stage},
         idx,
         node,
         cmd
       ) do
    if Map.get(stage, idx, @p1_stage) == @p1_stage do
      process_valid_proposal(
        %{state | mvc_stage: Map.put_new(stage, idx, @p1_stage)},
        idx,
        cmd
      )
    else
      if Map.get(stage, idx) == @decided do
        Logger.warning(
          "#{whoami()} received proposal from #{inspect(node)} " <>
            "about decided index #{idx}"
        )

        send(node, Rabia.ProtocolMessage.decided(idx, Map.get(state.cmd_log, idx)))
        state
      else
        Logger.warning(
          "#{whoami()} Received proposal from #{inspect(node)} for " <>
            "#{idx}, but have already transitioned to Ben-Or"
        )

        state
      end
    end
  end

  @bot :bot
  @cmd :cmd
  # Process an actual proposal received from another node.
  defp process_valid_proposal(
         state = %Rabia{weak_mvc_proposals: p, quorum_size: q, weak_mvc_state_cmd: scmd},
         idx,
         cmd = %Rabia.TimestampedCommand{timestamp: cid}
       ) do
    {count, proposals} =
      Map.get(p, idx, %{})
      |> Map.get_and_update(
        cid,
        fn v -> if v, do: {v + 1, v + 1}, else: {1, 1} end
      )

    n_proposals = Map.values(proposals) |> Enum.sum()
    state = %{state | weak_mvc_proposals: Map.put(p, idx, proposals)}

    cond do
      # Some proposal just received
      count >= q ->
        # Transition to Ben-Or with state cmd.
        Logger.notice("#{whoami()},#{idx} going to Ben-Or with state #{inspect(cmd)}")

        # Doing this here removes a chance that delays or processing order
        # causes us trouble
        %{state | weak_mvc_state_cmd: Map.put(scmd, idx, cmd)}
        |> transition_to_phase2state(
          idx,
          1,
          cmd
        )

      n_proposals >= q ->
        # Transition to Ben-Or with state bot.
        Logger.notice("#{whoami()},#{idx} going to Ben-Or with state #{:bot}")
        transition_to_phase2state(state, idx, 1, @bot)

      true ->
        %{state | weak_mvc_proposals: Map.put(p, idx, proposals)}
    end
  end

  # Phase 1 -> 2 transition
  # Transition to Phase 2 state processing for round
  # `round`.
  defp transition_to_phase2state(
         state = %Rabia{weak_mvc_chosen_command: commands},
         idx,
         round,
         smsg
       ) do
    update_round(
      %{
        state
        | weak_mvc_chosen_command: Map.put(commands, idx, smsg)
      },
      idx,
      round
    )
    |> send_state_message(idx)
    |> replay_enqueued_state_messages(idx)
  end

  # Called whenever the Ben-Or round is updates.
  defp update_round(
         state = %Rabia{
           weak_mvc_round: rounds,
           mvc_stage: stages,
           weak_mvc_state_messages: smsgs,
           queued_vote_messages: vmsgs,
           weak_mvc_vote: votes
         },
         idx,
         new_round
       ) do
    %{
      state
      | mvc_stage: Map.put(stages, idx, @p2s_stage),
        weak_mvc_round: Map.put(rounds, idx, new_round),
        weak_mvc_state_messages: Map.delete(smsgs, idx),
        weak_mvc_vote: Map.delete(votes, idx),
        queued_vote_messages: Map.delete(vmsgs, idx)
    }
  end

  # Send state messages to everyone.
  defp send_state_message(
         state = %Rabia{weak_mvc_chosen_command: commands, weak_mvc_round: rounds},
         idx
       ) do
    cmd = Map.get(commands, idx)
    round = Map.get(rounds, idx)

    sm =
      if cmd == @bot do
        ProtocolMessage.state_message(idx, round, @bot, cmd)
      else
        ProtocolMessage.state_message(idx, round, @cmd, cmd)
      end

    bcast(state, sm)
    state
  end

  # In Rabia, a node should not process state messages until it has
  # received a sufficient number of proposals. We do so by queuing
  # up :state messages and then re-injecting them when here.
  defp replay_enqueued_state_messages(
         state = %Rabia{queued_state_messages: msg_q},
         idx
       ) do
    Map.get(msg_q, idx, [])
    |> Enum.reverse()
    |> Enum.map(fn m -> send(whoami(), m) end)

    %{state | queued_state_messages: Map.delete(msg_q, idx)}
  end

  # Phase 2: State messages
  # Called by the `run` function to process a received state message.
  defp process_state_message(
         state = %Rabia{
           mvc_stage: stage,
           queued_state_messages: msg_q,
           weak_mvc_round: rounds
         },
         idx,
         node,
         smsg = %Rabia.StateMessage{round: r},
         msg
       ) do
    if Map.get(stage, idx) == @p2s_stage and Map.get(rounds, idx, 0) == r do
      count_state_message(state, idx, node, smsg)
    else
      if Map.get(stage, idx) == @decided do
        Logger.warning(
          "#{whoami()} received state message from #{inspect(node)} " <>
            "about decided index #{idx}"
        )

        send(node, Rabia.ProtocolMessage.decided(idx, Map.get(state.cmd_log, idx)))
        state
      else
        if Map.get(rounds, idx, 0) <= r do
          %{state | queued_state_messages: Map.update(msg_q, idx, [msg], fn q -> [msg | q] end)}
        else
          Logger.warning(
            "#{whoami()} droping state message from old round (#{r}, #{Map.get(rounds, idx)})"
          )

          state
        end
      end
    end
  end

  @cmd_vote :cmd
  @question_vote :qmark

  # Process a state message for this round, by counting them
  # and deciding what the node should vote for.
  defp count_state_message(
         state = %Rabia{
           quorum_size: q,
           weak_mvc_state_messages: s
         },
         idx,
         _node,
         msg = %Rabia.StateMessage{
           round: r,
           state: t,
           command: cmd
         }
       ) do
    {count, smsgs} =
      Map.get(s, idx, %{})
      |> Map.get_and_update(
        t,
        fn v -> if v, do: {v + 1, v + 1}, else: {1, 1} end
      )

    n_smsgs = Map.values(smsgs) |> Enum.sum()

    state =
      %{state | weak_mvc_state_messages: Map.put(s, idx, smsgs)}
      |> update_state_cmd(idx, msg)

    cond do
      count >= q ->
        Logger.notice("#{whoami()},#{idx} Round #{r} vote for command #{inspect(cmd)}")
        transition_to_phase2vote(state, idx, r, @cmd_vote, cmd)

      n_smsgs >= q ->
        Logger.notice("#{whoami()},#{idx} Round #{r} vote for ?")
        transition_to_phase2vote(state, idx, r, @question_vote)

      true ->
        state
    end
  end

  # This is from the errata: we need to track the set of commands
  # included in state messages, so we can refer to it when we arrive
  # at the point where a coin has to be tossed.
  defp update_state_cmd(
         state = %Rabia{weak_mvc_state_cmd: scmds},
         idx,
         %Rabia.StateMessage{
           state: t,
           command: cmd
         }
       ) do
    Logger.notice("#{whoami()},#{idx} update state command #{inspect(cmd)} (#{inspect(t)})")

    if t == @cmd do
      check_assumption(
        Map.get(scmds, idx, cmd) == cmd,
        "More than 1 non-bot command in the mix."
      )

      %{state | weak_mvc_state_cmd: Map.put(scmds, idx, cmd)}
    else
      state
    end
  end

  # Phase 2: State -> Vote transition
  defp transition_to_phase2vote(
         state = %Rabia{
           mvc_stage: stage,
           weak_mvc_vote: votes,
           weak_mvc_vote_cmds: vcmds
         },
         idx,
         round,
         vote,
         command \\ nil
       ) do
    msg = Rabia.ProtocolMessage.vote_message(idx, round, vote, command)
    bcast(state, msg)

    state =
      if vote == @cmd_vote do
        %{state | weak_mvc_vote_cmds: Map.put(vcmds, idx, command)}
      else
        state
      end

    %{
      state
      | mvc_stage: Map.put(stage, idx, @p2v_stage),
        weak_mvc_vote: Map.put(votes, idx, vote)
    }
    |> replay_enqueued_vote_msgs(idx)
  end

  # In Rabia, a node should not process votes until it has
  # receivd a sufficient number of state messages, and thus
  # decided its own state. We do so by queuing up vote messages
  # and then re-injecting them when here.
  defp replay_enqueued_vote_msgs(
         state = %Rabia{queued_vote_messages: vmsgq},
         idx
       ) do
    Map.get(vmsgq, idx, [])
    |> Enum.reverse()
    |> Enum.map(fn m -> send(whoami(), m) end)

    %{state | queued_vote_messages: Map.delete(vmsgq, idx)}
  end

  # Phase 2: Vote counting and decisions
  # Called by the `run` loop when a vote message is received.
  defp process_vote_message(
         state = %Rabia{mvc_stage: stage, weak_mvc_round: rounds, queued_vote_messages: vote_q},
         idx,
         node,
         vote = %Rabia.VoteMessage{round: r},
         msg
       ) do
    if Map.get(stage, idx) == @p2v_stage and Map.get(rounds, idx, 0) == r do
      count_votes(state, idx, node, vote)
    else
      if Map.get(stage, idx) == @decided do
        Logger.warning(
          "#{whoami()} received vote from #{inspect(node)} " <>
            "about decided index #{idx}"
        )

        send(node, Rabia.ProtocolMessage.decided(idx, Map.get(state.cmd_log, idx)))
        state
      else
        if Map.get(rounds, idx, 0) <= r do
          %{state | queued_vote_messages: Map.update(vote_q, idx, [msg], fn q -> [msg | q] end)}
        else
          Logger.warning(
            "#{whoami()},#{idx} droping vote message from old round (#{r}, #{Map.get(rounds, idx)})"
          )

          state
        end
      end
    end
  end

  # Process a vote by counting it.
  defp count_votes(
         state = %Rabia{weak_mvc_votes: votes_map, quorum_size: q},
         idx,
         _node,
         vote = %Rabia.VoteMessage{
           round: r,
           vote: v
         }
       ) do
    state = update_vote_command(state, idx, vote)

    votes =
      Map.get(votes_map, idx, %{})
      |> Map.update(v, 1, fn c -> c + 1 end)

    n_votes = Map.values(votes) |> Enum.sum()

    state = %{state | weak_mvc_votes: Map.put(votes_map, idx, votes)}

    if n_votes >= q do
      # We have enough votes to run the decision process
      end_benor_round(state, idx, r)
    else
      state
    end
  end

  # Used to keep track of what command we are voting for. For
  # convenience we track votes without commands.
  defp update_vote_command(
         state = %Rabia{weak_mvc_vote_cmds: cmds},
         idx,
         %Rabia.VoteMessage{
           vote: v,
           command: c
         }
       ) do
    if v == @cmd_vote do
      check_assumption(
        Map.get(cmds, idx, c) == c,
        "#{idx} Two commands are in play. #{inspect(c)} " <>
          " || #{inspect(Map.get(cmds, idx))}}"
      )

      %{state | weak_mvc_vote_cmds: Map.put(cmds, idx, c)}
    else
      state
    end
  end

  # Called when the node has received enough vote messages to
  # decide on what should happen for this round of Ben-Or.
  defp end_benor_round(
         state = %Rabia{
           weak_mvc_vote: my_votes,
           weak_mvc_votes: votes_map,
           quorum_size: q,
           weak_mvc_vote_cmds: vcmds,
           weak_mvc_state_cmd: scmds
         },
         idx,
         round
       ) do
    votes = Map.get(votes_map, idx)

    check_assumption(
      map_size(votes) == 1 or map_size(votes) == 2,
      "More than two types of votes?"
    )

    cond do
      Map.get(votes, @cmd_vote, 0) >= q ->
        Logger.notice(
          "#{whoami()},#{idx} decided for " <>
            " #{inspect(Map.get(vcmds, idx))}"
        )

        decided(state, idx, Map.get(vcmds, idx))

      Map.get(votes, @cmd_vote, 0) >= 1 ->
        Logger.notice("#{whoami()}, #{idx} Need to go back to p2s with command")
        cmd = Map.get(vcmds, idx)
        transition_to_phase2state(state, idx, round + 1, cmd)

      Map.get(my_votes, idx, @question_vote) == @cmd_vote ->
        Logger.notice("#{whoami()}, #{idx} Need to go back to p2s with command")
        cmd = Map.get(vcmds, idx)
        check_assumption(cmd != nil, "Must know what we voted for")
        transition_to_phase2state(state, idx, round + 1, cmd)

      # We only got a lot of ?-votes
      true ->
        coin = common_coin(idx, round)
        cmd = Map.get(scmds, idx, nil)
        check_assumption(cmd != nil, "#{idx} Got only ?-votes without a command")

        if coin == 0 do
          transition_to_phase2state(state, idx, round + 1, cmd)
        else
          transition_to_phase2state(state, idx, round + 1, @bot)
        end

        state
    end
  end

  # Common coin: Returns 0 or 1.
  defp common_coin(idx, round) do
    {n, _} = :rand.uniform_s(:rand.seed(:exsss, idx * round))
    round(n)
  end

  # Called when a command has been decided. This can be either because
  # Ben-Or successfully committed a command, or we received a message
  # indicating this.
  defp decided(
         state = %Rabia{
           weak_mvc_my_proposal: proposals,
           propose_queue: pq,
           mvc_stage: stage,
           cmd_log: log
         },
         idx,
         committed
       ) do
    check_assumption(
      Map.get(stage, idx) != @decided or Map.get(log, idx) == committed,
      "Violating agreement"
    )

    # Do not decide twice
    if Map.get(stage, idx) == @decided do
      state
    else
      state = %{
        state
        | mvc_stage: Map.put(stage, idx, @decided),
          cmd_log: Map.put(log, idx, committed)
      }

      # TODO: You should call into your code here to decide
      # when to execute commands. It might help to remember
      # state.mvc_state is a map from slot to state machine state.
      #          You should only execute a command at slot i
      #          if (a) you have executed commands for all slots
      #          from 1..i-1; and
      #          (b) Map.get(state.cmd_log, i) == @decided
      # state.cmd_log is a map from slot to the command at that
      # slot. Execute it by calling execute_cmd (below).
      # state.pending_requests is a map from a unique command ID
      # (returned by execute_cmd) to a client name. You should
      # send a response to the client if and only if this map
      # contains a command ID (we only add it on the node that
      # received the original client request).
      state = if idx == state.last_exec_seq + 1 do
                new_state = %{ state | last_exec_seq: state.last_exec_seq + 1 }
                new_state |> execute_and_send_response(committed) |> replay_decided_message()  
              else
                #If the prev log idx is not committed store in pending decided messages to execute later
                %{ state | mvc_stage: stage, cmd_log: log, pending_decided_messages: Map.put(state.pending_decided_messages, idx, committed) }
              end  

      desired = Map.get(proposals, idx, nil)

      if desired != nil and committed != desired do
        %{
          state
          | propose_queue: Prioqueue.insert(pq, desired)
        }
        |> propose_next_command()
      else
        state
      end
    end
  end

  defp execute_and_send_response(state, commitment) do
    {state, ts, response} = execute_cmd(state, commitment)    
    if ts != nil and Map.has_key?(state.pending_requests, ts) do
      client = Map.get(state.pending_requests, ts)
      send(client, response)
      %{state | pending_requests: Map.delete(state.pending_requests, ts)}
    else
      state
    end
  end

  defp replay_decided_message(state) do
    idx = state.last_exec_seq + 1
    if Map.has_key?(state.pending_decided_messages, idx) do
      commited = Map.get(state.pending_decided_messages, idx)
      state = %{state | pending_decided_messages: Map.delete(state.pending_decided_messages, idx)}
      decided(state, idx, commited)
    else
      state
    end
  end

  @doc """
  Executes command `cmd`.

  Returns a tuple with:
     * Updated `state`
     * A command ID (Rabia.Timestamp) that you should use to check
       `state.pending_requests` or nil if we committed :bot.
     * The response to send back to the client.
  """
  @spec execute_cmd(
          %Rabia{:counter => integer()},
          :bot
          | %Rabia.TimestampedCommand{
              :command => %Rabia.Command{
                :args => any(),
                :client_seq => any(),
                :operation => :get | :inc | :nop
              },
              :timestamp => %Rabia.Timestamp{}
            }
        ) ::
          {%Rabia{:counter => integer}, nil | %Rabia.Timestamp{}, nil | %Rabia.CommandResponse{}}
  def execute_cmd(state = %Rabia{counter: counter}, cmd) do
    case cmd do
      :bot ->
        {state, nil, nil}

      %Rabia.TimestampedCommand{timestamp: ts, command: cmd} ->
        %Rabia.Command{client_seq: cs, operation: op, args: arg} = cmd

        case op do
          :nop -> {state, ts, Rabia.CommandResponse.nop_response(cs)}
          :get -> {state, ts, Rabia.CommandResponse.get_response(cs, counter)}
          :inc -> {%{state | counter: counter + arg}, ts, Rabia.CommandResponse.inc_response(cs)}
        end
    end
  end

  # Called by `run` when it receives a new command. Performs the function
  # attributed to a proxy in the Rabia paper, and replicates the command,
  # adding it (eventually) to everyone's priority queue. Also responsible
  # for keeping track of what client requests were received by this node.
  defp handle_client_command(state, client, cmd) do
    msg_id = Rabia.Timestamp.new(whoami(), state.cmd_seq)

    pmsg =
      Rabia.ProtocolMessage.replicate_propsal(
        msg_id,
        cmd
      )

    bcast(state, pmsg)

    %{
      state
      | pending_requests: Map.put(state.pending_requests, msg_id, client),
        cmd_seq: state.cmd_seq + 1
    }
  end

  @moduledoc """
  Run a node of Rabia. Called with a `%Rabia` structure,
  you can create one by calling `Rabia.new_configuration/1`
  """
  @spec run(%Rabia{
          cmd_seq: non_neg_integer()
        }) :: no_return()
  def run(state) do
    receive do
      {client, cmd = %Rabia.Command{}} ->
        run(handle_client_command(state, client, cmd))

      {_, %Rabia.ProtocolMessage{type: :replicate, node: _n, contents: c}} ->
        run(
          propose_next_command(%{state | propose_queue: Prioqueue.insert(state.propose_queue, c)})
        )

      {_, %Rabia.ProtocolMessage{type: :proposal, node: w, log_idx: i, contents: c}} ->
        run(process_proposal(state, i, w, c))

      {_,
       m = %Rabia.ProtocolMessage{
         type: :state,
         node: w,
         log_idx: i,
         contents: c = %Rabia.StateMessage{}
       }} ->
        run(process_state_message(state, i, w, c, m))

      {_,
       m = %Rabia.ProtocolMessage{
         type: :vote,
         node: w,
         log_idx: i,
         contents: c = %Rabia.VoteMessage{}
       }} ->
        run(process_vote_message(state, i, w, c, m))

      {_,
       %Rabia.ProtocolMessage{
         type: :decided,
         log_idx: idx,
         contents: c
       }} ->
        run(decided(state, idx, c))

      {_, :dump_node_state} ->
        # Debugging
        Logger.notice("Dumping proposal queue for #{whoami()}")

        Logger.notice(
          Enum.map_join(
            state.propose_queue,
            "\n\t",
            fn x -> "#{inspect(x)}" end
          )
        )

        Logger.notice("Dumping pending requests for #{whoami()}")

        Logger.notice(
          Enum.map_join(
            state.pending_requests,
            "\n\t",
            fn x -> "#{inspect(x)}" end
          )
        )

        Logger.notice("Dumping log for #{whoami()}")

        Logger.notice(
          Enum.map_join(
            state.cmd_log,
            "\n\t",
            fn x -> "#{inspect(x)}" end
          )
        )

        run(state)

      m ->
        IO.inspect(m)
        run(state)
    end
  end
end
