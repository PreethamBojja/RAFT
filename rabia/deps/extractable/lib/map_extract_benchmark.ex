defmodule MapList do
  @doc "Original implementation"
  def extract(map) do
    case :maps.to_list(map) do
      [elem | rest_list] ->
        {:ok, {elem, :maps.from_list(rest_list)}}

      [] ->
        {:error, :empty}
    end
  end
end

defmodule MapKeys do
  @doc "Implementation based on Map.keys"
  def extract(map) do
    case Map.keys(map) do
      [key | _rest] ->
        {value, rest} = Map.pop(map, key)
        element = {key, value}
        {:ok, {element, rest}}

      [] ->
        {:error, :empty}
    end
  end
end

defmodule MapKeysInverted do
  @doc "Implementation based on Map.keys"
  def extract(map) do
    case Map.keys(map) do
      [] ->
        {:error, :empty}

      [key | _rest] ->
        {value, rest} = Map.pop(map, key)
        element = {key, value}
        {:ok, {element, rest}}
    end
  end
end

defmodule MapKeysSize do
  @doc "Implementation based on Map.keys with extra `map_size` short-circuit"
  def extract(map) when map_size(map) == 0, do: {:error, :empty}

  def extract(map) do
    [key | _] = Map.keys(map)
    {value, rest} = Map.pop(map, key)
    element = {key, value}
    {:ok, {element, rest}}
  end
end

defmodule MapKeysSizeInverted do
  @doc "Implementation based on Map.keys with extra `map_size` short-circuit"
  def extract(map) when map_size(map) > 0 do
    [key | _] = Map.keys(map)
    {value, rest} = Map.pop(map, key)
    element = {key, value}
    {:ok, {element, rest}}
  end

  def extract(_map), do: {:error, :empty}
end

defmodule MapKeysSizeInverted2 do
  @doc "Implementation based on Map.keys with extra `map_size` short-circuit"
  def extract(map) when map_size(map) > 0 do
    [key | _] = Map.keys(map)
    {value, rest} = Map.pop(map, key)
    element = {key, value}
    {:ok, {element, rest}}
  end

  def extract(map) when map_size(map) == 0, do: {:error, :empty}
end

defmodule MapIterator do
  @doc "Implementation based on `:maps.iterator`/`:maps.next`"
  def extract(map) do
    case map |> :maps.iterator() |> :maps.next() do
      {key, value, rest_iter} ->
        element = {key, value}
        rest = :maps.map(fn _key, val -> val end, rest_iter)
        {:ok, {element, rest}}

      :none ->
        {:error, :empty}
    end
  end
end

map_with_size = fn size ->
  1..size
  |> Enum.into(%{}, fn x -> {x, x} end)
end

# Benchee.run(
#   %{
#     "MapKeys" => &MapKeys.extract/1,
#     "MapKeysInverted" => &MapKeysInverted.extract/1,
#     "MapKeysSize" => &MapKeysSize.extract/1,
#     "MapKeysSizeInverted" => &MapKeysSizeInverted.extract/1,
#     "MapKeysSizeInverted2" => &MapKeysSizeInverted2.extract/1,
#     "MapList" => &MapList.extract/1,
#     "MapIterator" => &MapIterator.extract/1
#   },
#   inputs: [
#     empty: %{},
#     "10": map_with_size.(10),
#     "100": map_with_size.(100),
#     "1_000": map_with_size.(1_000),
#     "10_000": map_with_size.(10_000),
#     "1_000_000": map_with_size.(1_000_000)
#   ],
#   time: 3,
#   memory_time: 1
# )
