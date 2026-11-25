Code.require_file("process_lab.exs", __DIR__)
ExUnit.start()

defmodule MedFabric.Acceptance.ProcessLabTest do
  use ExUnit.Case, async: false
  alias MedFabric.Acceptance.ProcessLab

  test "reports real exit status and terminates an owned process group" do
    directory =
      Path.join(System.tmp_dir!(), "mf-process-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(directory, "logs"))
    Process.flag(:trap_exit, true)
    ProcessLab.init(directory, 20_000)

    try do
      success = ProcessLab.run!("success", "sh", ["-c", "exit 0"], directory, System.get_env())
      assert ProcessLab.status(success) == 0

      normal_nine =
        ProcessLab.launch!("normal-nine", "sh", ["-c", "exit 9"], directory, System.get_env())

      assert ProcessLab.await!(normal_nine, 5_000) == 9
      assert ProcessLab.status(normal_nine) == 9

      normal_failure =
        ProcessLab.launch!("normal-failure", "sh", ["-c", "exit 42"], directory, System.get_env())

      assert ProcessLab.await!(normal_failure, 5_000) == 42

      victim = ProcessLab.launch!("victim", "sleep", ["60"], directory, System.get_env())
      assert :ok == ProcessLab.kill!(victim)
      assert ProcessLab.status(victim) == 137

      assert_raise RuntimeError, ~r/Deadline expired/, fn ->
        ProcessLab.wait!(fn -> false end, 100, nil, "test deadline")
      end
    after
      ProcessLab.close!()
      File.rm_rf!(directory)
    end
  end
end
