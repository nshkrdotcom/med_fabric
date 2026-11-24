defmodule MedFabric.Exam.DeviceRootLockTest do
  use ExUnit.Case, async: false

  alias MedEx.StreamWriter
  alias MedFabric.Exam.DeviceRootLock

  @fixture Path.expand("support/device_root_owner.exs", __DIR__)
  @timeout 10_000

  @tag :tmp_dir
  test "a contender is refused and replacement waits for actual owner VM death", %{tmp_dir: root} do
    first = launch(root, "write")
    [first_pid, helper_pid] = line(first, "ready")
    assert {:os_pid, String.to_integer(first_pid)} == Port.info(first, :os_pid)

    contender = launch(root, "recover")
    assert [] = line(contender, "refused")
    assert_receive {^contender, {:exit_status, 78}}, @timeout
    assert {"", 0} = signal("-0", first_pid)

    assert {"", 0} = signal("-KILL", helper_pid)
    assert_receive {^first, {:exit_status, 1}}, @timeout
    assert {_, 1} = signal("-0", first_pid)

    replacement = launch(root, "recover")
    [replacement_pid, _] = line(replacement, "ready")
    assert {"", 0} = signal("-KILL", replacement_pid)
    assert_receive {^replacement, {:exit_status, 137}}, @timeout
    assert {_, 1} = signal("-0", replacement_pid)

    recovered = launch(root, "recover")
    assert [_, _] = line(recovered, "ready")
    assert Port.command(recovered, "stop\n")
    assert_receive {^recovered, {:exit_status, 0}}, @timeout
  end

  defp signal(kind, pid),
    do: System.cmd("kill", [kind, pid], stderr_to_stdout: true)

  defp launch(root, mode) do
    paths = for app <- [DeviceRootLock, StreamWriter], do: Path.dirname(:code.which(app))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ [@fixture, mode, root]
    elixir = System.find_executable("elixir")

    Port.open({:spawn_executable, elixir}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4096},
      {:args, args},
      {:env, [{~c"ERL_FLAGS", ~c"+S 2:2"}]}
    ])
  end

  defp line(port, tag),
    do: line(port, tag, System.monotonic_time(:millisecond) + @timeout, [])

  defp line(port, tag, deadline, output) do
    receive do
      {^port, {:data, {_, line}}} ->
        case String.split(line) do
          [^tag | rest] -> rest
          _ -> line(port, tag, deadline, [line | output])
        end

      {^port, {:exit_status, status}} ->
        flunk("Owner BEAM exited #{status} while waiting for #{tag}: #{format_output(output)}")
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("Owner BEAM did not report #{tag}: #{format_output(output)}")
    end
  end

  defp format_output(output), do: output |> Enum.reverse() |> Enum.join("\n")
end
