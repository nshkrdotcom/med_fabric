Code.require_file("process_lab.exs", __DIR__)
ExUnit.start()

defmodule MedFabric.Acceptance.ProcessLabTest do
  use ExUnit.Case, async: false
  alias MedFabric.Acceptance.ProcessLab

  test "reports real exit status and terminates an owned process group" do
    directory = Path.join(System.tmp_dir!(), "mf-process-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "logs"))
    Process.flag(:trap_exit, true)
    ProcessLab.init(directory, 20_000)
    try do
      success = ProcessLab.run!("success", "sh", ["-c", "exit 0"], directory, System.get_env())
      assert ProcessLab.status(success) == 0
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
