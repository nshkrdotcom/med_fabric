defmodule MedFabric.Exam.BackgroundWorkersTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MedFabric.Exam.{AcquisitionExpiry, DeliveryWorker}

  test "due-query failure is handled by the real worker without a crash report or busy loop" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    log = capture_log(fn ->
      worker = start_supervised!({DeliveryWorker, %{db: dead}})
      monitor = Process.monitor(worker)
      refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 600
      assert Process.alive?(worker)
      {:message_queue_len, size} = Process.info(worker, :message_queue_len)
      assert size <= 1
    end)

    assert log =~ "delivery_poll_failed"
    refute log =~ "crasher"
    refute log =~ "Last message"
  end

  test "delivery and expiry are siblings under one real one-for-one supervisor" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    {:ok, supervisor} = MedFabric.Exam.Application.background(%{db: dead}, nil)
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    children = Map.new(Supervisor.which_children(supervisor), fn {id, pid, _, _} -> {id, pid} end)
    expiry = children[AcquisitionExpiry]
    delivery = children[DeliveryWorker]
    monitor = Process.monitor(delivery)
    Process.exit(delivery, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^delivery, :killed}
    replacement = child(supervisor, DeliveryWorker, delivery)
    assert is_pid(replacement) and replacement != delivery
    assert Process.alive?(expiry)
  end

  defp child(supervisor, id, old, attempts \\ 100)
  defp child(_, _, _, 0), do: flunk("background worker did not restart")

  defp child(supervisor, id, old, attempts) do
    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      {^id, pid, _, _} when is_pid(pid) and pid != old -> pid
      _ ->
        Process.sleep(10)
        child(supervisor, id, old, attempts - 1)
    end
  end
end
