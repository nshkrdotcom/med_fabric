defmodule MedExHandheld.MonitorTest do
  use ExUnit.Case, async: true
  alias MedExHandheld.Monitor

  @tag :tmp_dir
  test "cache exhaustion still permits replay and denies new stale rejections", %{tmp_dir: dir} do
    command = command("0", "0")
    completed = Map.put(command, "status", "applied")
    cache = Map.new(0..4095, &{to_string(&1), completed})

    File.write!(
      Path.join(dir, "monitor.json"),
      JSON.encode!(%{"boot" => "boot", "epoch" => "1", "gain" => "unity", "cache" => cache})
    )

    monitor = start_supervised!({Monitor, {dir, "boot"}})
    assert {:result, ^completed} = GenServer.call(monitor, {:command, command})

    assert {:error, :command_cache_exhausted} =
             GenServer.call(monitor, {:command, command("new", "0")})
  end

  @tag :tmp_dir
  test "pending identity is protected and epochs must use canonical decimal strings", %{
    tmp_dir: dir
  } do
    monitor = start_supervised!({Monitor, {dir, "boot"}})

    for malformed <- ["00", "+0"] do
      assert {:result, %{"status" => "rejected"}} =
               GenServer.call(monitor, {:command, command(malformed, malformed)})
    end

    command = command("pending", "0")
    assert :pending = GenServer.call(monitor, {:command, command})
    assert :pending = GenServer.call(monitor, {:command, command})

    assert {:error, :conflict} =
             GenServer.call(monitor, {:command, %{command | "fingerprint" => "other"}})

    assert {"1", <<2, 0>>} = GenServer.call(monitor, {:frame, 0, <<4, 0>>})
    assert {:result, %{"status" => "applied"}} = GenServer.call(monitor, {:command, command})
  end

  defp command(id, epoch) do
    %{
      "id" => id,
      "fingerprint" => "hash",
      "boot" => "boot",
      "gain" => "half",
      "expected_epoch" => epoch
    }
  end
end
