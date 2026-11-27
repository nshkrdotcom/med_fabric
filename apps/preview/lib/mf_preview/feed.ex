defmodule MedFabric.Preview.Feed do
  @moduledoc false
  use GenServer
  alias MedFabric.Preview.Capability
  @table :mf_preview_feed

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def init(config) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    :ets.insert(@table, [{:requests, 0}, {:request_limit, config[:max_peers] * 2}])
    Process.send_after(self(), :sweep, 1_000)
    {:ok, %{entries: %{}, refs: %{}, config: config}}
  end
  def reserve(grant, create?), do: GenServer.call(__MODULE__, {:reserve, grant, create?}, 1_000)
  def attach(key, ticket, pid), do: GenServer.call(__MODULE__, {:attach, key, ticket, pid}, 1_000)
  def release(key, ticket), do: GenServer.cast(__MODULE__, {:release, key, ticket})

  def offer(source, frame) do
    now = System.monotonic_time(:millisecond)
    wall = System.system_time(:millisecond)
    for {{:peer, key}, pid, grant} <- :ets.tab2list(@table),
        Capability.source(grant) == source and Capability.current?(grant, now, wall) do
      if Process.alive?(pid) and feed_credit?(key), do: :ets.insert(@table, {{:frame, key}, now, source, frame})
    end
    :ok
  rescue
    ArgumentError -> :ok
  end

  def take(key) do
    case :ets.take(@table, {:frame, key}) do
      [{_, at, source, frame}] -> {:ok, at, source, frame}
      [] -> :empty
    end
  rescue
    ArgumentError -> :empty
  end
  def clear(key) do
    :ets.delete(@table, {:frame, key})
    :ok
  rescue
    ArgumentError -> :ok
  end
  def update(key, pid, grant) do
    :ets.insert(@table, {{:peer, key}, pid, grant})
    :ets.insert_new(@table, {{:rate, key}, :atomics.new(1, signed: false)})
    :ok
  rescue
    ArgumentError -> {:error, :feed_unavailable}
  end
  def enter(key, token) do
    count = :ets.update_counter(@table, :requests, {2, 1})
    limit = :ets.lookup_element(@table, :request_limit, 2)
    if count <= limit and :ets.insert_new(@table, {{:request, key}, token, self(), System.monotonic_time(:millisecond)}) do
      true
    else
      :ets.update_counter(@table, :requests, {2, -1})
      false
    end
  rescue
    ArgumentError -> false
  end
  def leave(key, token) do
    case :ets.lookup(@table, {:request, key}) do
      [{{:request, ^key}, ^token, owner, at}] ->
        count = :ets.select_delete(@table, [{{{:request, key}, token, owner, at}, [], [true]}])
        if count == 1, do: :ets.update_counter(@table, :requests, {2, -1})
      _ -> :ok
    end
    :ok
  rescue
    ArgumentError -> :ok
  end
  defp feed_credit?(key) do
    case :ets.lookup(@table, {:rate, key}) do
      [{_, ref}] -> take_rate(ref, div(System.system_time(:millisecond), 1_000), 5)
      _ -> false
    end
  end
  defp take_rate(_, _, 0), do: false
  defp take_rate(ref, second, attempts) do
    old = :atomics.get(ref, 1)
    current_second = div(old, 256)
    count = rem(old, 256)
    next = if current_second == second, do: old + 1, else: second * 256 + 1
    cond do
      current_second == second and count >= 100 -> false
      :atomics.compare_exchange(ref, 1, old, next) == :ok -> true
      true -> take_rate(ref, second, attempts - 1)
    end
  end

  def handle_call({:reserve, grant, create?}, _, s) do
    key = Capability.key(grant)
    existing = s.entries[key]
    source_count = Enum.count(s.entries, fn {{source, _, _}, _} -> source == elem(key, 0) end)
    cond do
      existing && is_pid(existing.pid) -> {:reply, {:ok, existing.pid}, s}
      existing -> {:reply, {:error, :busy}, s}
      not create? -> {:reply, :absent, s}
      map_size(s.entries) >= s.config[:max_peers] or source_count >= s.config[:max_source_peers] ->
        {:reply, {:error, :capacity}, s}
      true ->
        ticket = make_ref()
        entry = %{ticket: ticket, pid: nil, at: System.monotonic_time(:millisecond)}
        {:reply, {:reserved, ticket}, %{s | entries: Map.put(s.entries, key, entry)}}
    end
  end

  def handle_call({:attach, key, ticket, pid}, _, s) do
    case s.entries[key] do
      %{ticket: ^ticket, pid: nil} = entry ->
        ref = Process.monitor(pid)
        {:reply, :ok, %{s | entries: Map.put(s.entries, key, %{entry | pid: pid}), refs: Map.put(s.refs, ref, {key, ticket})}}
      _ -> {:reply, {:error, :reservation_lost}, s}
    end
  end
  def handle_cast({:release, key, ticket}, s), do: {:noreply, remove(s, key, ticket)}
  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.pop(s.refs, ref) do
      {nil, _} -> {:noreply, s}
      {{key, ticket}, refs} -> {:noreply, remove(%{s | refs: refs}, key, ticket)}
    end
  end
  def handle_info(:sweep, s) do
    now = System.monotonic_time(:millisecond)
    next = Enum.reduce(s.entries, s, fn {key, entry}, acc ->
      if entry.pid == nil and now - entry.at >= 8_000, do: remove(acc, key, entry.ticket), else: acc
    end)
    for {{:request, key}, token, owner, _at} <- :ets.tab2list(@table),
        not Process.alive?(owner) do
      leave(key, token)
    end
    Process.send_after(self(), :sweep, 1_000)
    {:noreply, next}
  end
  defp remove(s, key, ticket) do
    case s.entries[key] do
      %{ticket: ^ticket} ->
        case :ets.lookup(@table, {:request, key}) do
          [{_, token, _, _}] -> leave(key, token)
          _ -> :ok
        end
        for kind <- [:peer, :frame, :rate], do: :ets.delete(@table, {kind, key})
        %{s | entries: Map.delete(s.entries, key)}
      _ -> s
    end
  end
end
