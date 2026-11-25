defmodule MedExHandheld.Monitor do
  @moduledoc "Persistent per-boot absolute monitor setting, applied at an observed audio-frame boundary."
  use GenServer
  alias MedExHandheld.Spool
  def start_link({dir, boot}), do: GenServer.start_link(__MODULE__, {dir, boot})

  def init({dir, boot}) do
    file = Path.join(dir, "monitor.json")

    state =
      Spool.read_json(file, %{"boot" => boot, "epoch" => "0", "gain" => "unity", "cache" => %{}})

    if state["boot"] != boot, do: raise("monitor boot domain changed")
    {:ok, %{file: file, state: state, pending: nil}}
  end

  def handle_call({:command, c}, _, s) do
    ledger =
      Map.new(s.state["cache"], fn {id, entry} ->
        {id, %{fingerprint: entry["fingerprint"], result: entry}}
      end)

    cmd = %{
      id: c["id"],
      fingerprint: c["fingerprint"],
      expected_epoch: parse_epoch(c["expected_epoch"])
    }

    case MedEx.ControlInterlock.device_decide(ledger, cmd, String.to_integer(s.state["epoch"])) do
      {:cached, r} ->
        {:reply, {:result, r}, s}

      {:error, :command_id_conflict} ->
        {:reply, {:error, :conflict}, s}

      {:error, :stale_configuration} ->
        reject_command(c, s)

      {:execute_and_persist_result, _} ->
        accept_command(c, s)
    end
  end

  def handle_call({:frame, first, pcm}, _, s) do
    state =
      if c = s.pending do
        epoch = to_string(String.to_integer(s.state["epoch"]) + 1)

        result =
          Map.merge(Map.take(c, ~w(id fingerprint boot gain)), %{
            "status" => "applied",
            "epoch" => epoch,
            "first_sample" => to_string(first)
          })

        updated =
          s.state
          |> Map.merge(%{"epoch" => epoch, "gain" => c["gain"]})
          |> put_in(["cache", c["id"]], result)

        Spool.write!(s.file, JSON.encode!(updated))
        updated
      else
        s.state
      end

    {:reply, {state["epoch"], transform(pcm, state["gain"])}, %{s | state: state, pending: nil}}
  end

  def handle_call({:state, c}, _, s) do
    result =
      if s.pending && s.pending["id"] == c["id"] do
        %{"id" => c["id"], "status" => "pending"}
      else
        s.state["cache"][c["id"]] ||
          Map.merge(
            Map.take(c, ~w(id fingerprint)),
            Map.merge(Map.take(s.state, ~w(boot epoch gain)), %{
              "status" => "reconciled",
              "first_sample" => nil
            })
          )
      end

    {:reply, result, s}
  end

  defp accept_command(c, s) do
    cond do
      s.pending == c ->
        {:reply, :pending, s}

      map_size(s.state["cache"]) >= 4096 ->
        {:reply, {:error, :command_cache_exhausted}, s}

      not is_nil(s.pending) or c["boot"] != s.state["boot"] or c["gain"] not in ["unity", "half"] ->
        reject_command(c, s)

      true ->
        {:reply, :pending, %{s | pending: c}}
    end
  end

  defp reject_command(c, s) do
    rejected = Map.merge(Map.take(c, ~w(id fingerprint boot)), %{"status" => "rejected"})
    next = put_in(s.state, ["cache", c["id"]], rejected)
    Spool.write!(s.file, JSON.encode!(next))
    {:reply, {:result, rejected}, %{s | state: next}}
  end

  defp parse_epoch(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> :invalid
    end
  end

  defp parse_epoch(_), do: :invalid

  def transform(bytes, "unity"), do: bytes

  def transform(bytes, "half"),
    do: for(<<v::little-signed-16 <- bytes>>, into: <<>>, do: <<div(v, 2)::little-signed-16>>)
end
