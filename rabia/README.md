# Lab 4: Rabia (Spring 2024)
If it is not Spring 2024, then you do not want to be doing this version of the assignment.

## The Project
This project is about using Rabia. In [protocol.ex](apps/rabia/lib/protocol.ex) we provide you with a mostly complete implementation of Rabia. 

The implementation is meant to implement a linearizable counter that implements `increment` and `get`. Unfortunately, while it commits to the log, it does not execute these commands. Your main task is to finish this. 

To do so, you will need to add a function and call it from the `decided` function. Please remember that you must execute logged commands in order, but Rabia (unlike Raft) does not guarantee that log entries are committed in order.

Hints:
* The code structure is a bit similar to Raft: messages (both client messages and protocol messages) are in [messages.ex](apps/rabia/lib/messages.ex) while the actual protocol is in [protocol.ex](apps/rabia/lib/protocol.ex). 
* You need to use the `execute_cmd` function, which returns the content of the response you should send clients.
* A client should receive exactly one response, from the server that originally received its request. As a reminder, Rabia does not have a leader, so a request can be received by any server. The code already keeps track in the `pending_requests` map in the appropriate Rabia server's state.
* Reading code is a big part of this lab. Among other things, you might want to read it just to get a better sense of Rabia.

### Testing

As usual, you can test your code by running `mix test`. Note, that the tests in this case are limited: a correct submission must successfully pass them, but passing them does not necessarily guarantee correctness.

The main problem is that the tests do not adequately test scenarios where you try to apply a log entry before its preceding log entries have been applied: tests for these would be a bit flaky, and lead to confusion. You can (and should) try to write your own (extending the [testing code](apps/rabia/test/rabia_test.exs) should be relatively simple).

## Extra Credit (15 points)
Please note: you do not need to do this and gaining the full 25 points might require an unusually large amount of work. It might be fun, but we do not necessarily recommend it.

The implementation can get into a live lock (a case where even though Ben-Or terminates, and nodes remain alive, a client command is never executed, and the log keeps growing) when two different nodes are processing client commands simultaneously. To see this, run `iex -S mix` from a shell (you will get a shell with `iex(1)>`) and run the following (`>` indicates the `iex` prompt):
```
> emulation.init()
> # Nodes
> n = [:a, :b, :c]
> # Start three processes
> n |> Enum.map(fn x -> Emulation.spawn(x, fn -> Rabia.run(Rabia.new_configuration(n)) end) end)
> # Issue client commands from :a and :b
> [:a, :b] |> Enum.map(fn x -> Emulation.send(x, Rabia.Command.nop(1)))
```

You might need to run it a few times, but you will soon find that the command is never committed, and new log entries (with the value `:bot`) keep getting committed. The extra credit involves two parts:

(a) Understand and write a brief explanation (in this Readme file) for what leads to this live lock. [5 points]

For livelock to occur, the Rabia protocol should commit :bot at each index, and the log should continue growing. In an ideal scenario, this can persist for a significant duration before eventually terminating. Some of the possible scenario's are as follows: Let's consider the first element of each priority queue, formatted as (command, client). a has (nop, a), b has (nop, b), and c could either have (nop, a) or (nop, b). However, without loss of generality, let's assume the element as (nop, a).

  (I) One of the simplest scenario is when all of the state values are :bot, then each server decides on :bot

   Server      Proposal       State      Votes     Decide 
 --------     ----------    ---------   -------   --------- 
    a           (nop,a)       :bot       :bot       :bot
    
    b           (nop,b)       :bot       :bot       :bot

    c           (nop,a)       :bot       :bot       :bot 

  (II) If two of them or :bot and one is (nop,a)

    WLOG lets assume server c has state (nop,a), and let the votes decided be :bot,?,? respectively

    Server          State            Votes        Received Votes      
   --------    ----------------     -------       ---------------
      a             :bot             :bot           :bot , ?                 
 
      b             :bot               ?            :bot , ?

      c            (nop,a)             ?               ? , ?
  
    From here, all three servers move to Round 2, but none of them terminates. Since "a" and "b" have at least one non-"?" command as a vote, they will move to Round 2 with the state ":bot," whereas server "c" moves to Round 2 with a coin toss, which can result in ":bot." Eventually, all three reaching ":bot" means the first case we saw above. Like these two, there are many scenarios that can lead to committing ":bot".

Now, coming to why this doesn't terminate eventually, from what I observed after the initial 6-8 commits of ":bot," there would be some delay in one of these servers starting to propose a value. This delay might occur because that server might have gone through an extra round in the previous index of the Rabia protocol, or the other servers would have terminated early in Ben-Or. Let's say, for the proposals, we assumed "a" and "b" start proposing for an index at a similar time, but "c" starts with a little delay. The outcome would be as follows:

     Server        Proposal       State      Votes     Decide 
    --------     -----------    ---------   -------   --------- 
        a           (nop,a)       :bot       :bot       :bot
    
        b           (nop,b)       :bot       :bot       :bot

This occurs without any interaction with "c," and immediately "a" and "b" start with a later index. Meanwhile, "c" would be catching up with the former index. This never ends because "a" and "b" keep committing ":bot," and "c" commits ":bot" after some delay because "a" and "b" decided on ":bot." This leads to livelock. I'll be showing an example I generated attached as file "Livelock.txt".

Let's observe what happens at index 7. On lines 359 and 363, "a" and "b" are proposing their values. Checking line 399 and 403, both "a" and "b" decide for index 7, whereas "c" starts proposing after this, at line 431. This delay continues to propagate for future indexes as well. Just for our understanding, looking at the end of the file, "a" and "b" are around index 19, whereas "c" is around 13, showing us the delay.

Note: The file Livelock.txt contains only partial logger outputs.

I have also attached NoLiveLock.txt, where there is termination. Here, we get a favorable case in the initial 5-6 indexes, and hence the delay doesn't affect us. The client commands are committed in the first 5-6 indexes without livelock.

(b) Propose (either in text or code) a fix for this live lock. [10 points]

One possible solution, as discussed in the paper, is using a failure detector for long-tail latency. Here, if a command is not executed for a significant duration, we can change the protocol to wait for all the state and vote messages from all live nodes (which we can know from the failure detector). This helps us address the delay that we encountered, which was the root cause of the livelock. Since in our lab no node ever crashes(so we don't need a failure detector), we can simply wait for all state and vote messages from all servers after a considerable amount of time.

Determining this "considerable amount of time" is a crucial thing where we need to decide how many ":bot" commits should occur before we wait for all state and vote messages. For this, we can maintain a map stating how many times the command was tried to commit and ":bot" got committed. After a particular threshold, we can conclude that the protocol has seen enough and should wait for all the state and vote messages. 

I have not implemented this, but I tried a more relaxed version where we wait for all the state and vote messages right from index 1, and I never encountered a livelock. I believe implementing this approach would help us fix the livelock issue.

## How to submit

**Warning** As usual you need to follow the instructions below to receive a grade on this lab.

* Add citations for anyone you collaborated with, or any sources you consulted while completing this lab.
* Make sure all your changes are committed, and pushed.
* Make sure `mix test` runs correctly.
* Use `git rev-parse --short HEAD` to get a commit hash for the final submission.
* Fill out the [submission form](https://forms.gle/5yfctb1L3To8Yevk6)/

I have used 2 late days and collaborated with Sujana Maithili.