defmodule RabiaTest do
  require Logger
  use ExUnit.Case
  doctest Rabia
  require Emulation
  require Logger

  test "Rabia responds to commands" do
    Emulation.init()
    # Going to use three nodes
    nodes = [:a, :b, :c]
    config = Rabia.new_configuration(nodes)

    nodes
    |> Enum.map(fn x ->
      Emulation.spawn(
        x,
        fn -> Rabia.run(config) end
      )
    end)

    client =
      Emulation.spawn(:client, fn ->
        Emulation.send(:a, Rabia.Command.nop(1))

        receive do
          {:a, %Rabia.CommandResponse{client_seq: 1, return: :ok}} ->
            true

          {c, %Rabia.CommandResponse{client_seq: n}} ->
            assert c == :a and n == 1
        end
      end)

    handle = Process.monitor(client)

    receive do
      {:DOWN, ^handle, _, _, _} -> true
    after
      1_000 -> assert false
    end
  after
    Emulation.terminate()
  end

  test "Rabia applies commands in order" do
    Emulation.init()
    # Going to use three nodes
    nodes = [:a, :b, :c]
    config = Rabia.new_configuration(nodes)

    nodes
    |> Enum.map(fn x ->
      Emulation.spawn(
        x,
        fn -> Rabia.run(config) end
      )
    end)

    client =
      Emulation.spawn(:client, fn ->
        Emulation.send(:a, Rabia.Command.inc(1, 2))

        receive do
          {:a, %Rabia.CommandResponse{client_seq: 1, return: :ok}} ->
            true

          {c, %Rabia.CommandResponse{client_seq: n}} ->
            assert c == :a and n == 1
        end

        Emulation.send(:b, Rabia.Command.get(2))

        receive do
          {:b, %Rabia.CommandResponse{client_seq: 2, return: 2}} ->
            true

          {c, %Rabia.CommandResponse{client_seq: n, return: v}} ->
            assert c == :b and n == 2 and v == 2
        end
      end)

    handle = Process.monitor(client)

    receive do
      {:DOWN, ^handle, _, _, _} -> true
    after
      1_000 -> assert false
    end
  after
    Emulation.terminate()
  end
end
