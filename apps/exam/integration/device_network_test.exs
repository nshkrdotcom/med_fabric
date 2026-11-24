defmodule MedFabric.DeviceNetworkTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 1_550_000

  @tag :tmp_dir
  test "external paired and spot-check producers verify real durable artifacts and reviewed outcomes",
       %{tmp_dir: directory} do
    on_exit(fn -> File.rm_rf!(directory) end)
    root = Path.expand("../../..", __DIR__)
    report = Path.join(directory, "report.json")
    suite = System.get_env("MF_NETWORK_SUITE", "paired")

    args = [
      "ops/handheld_acceptance.exs",
      "--suite",
      suite,
      "--report",
      report,
      "--preview",
      System.get_env("MF_NETWORK_PREVIEW", "off")
    ]

    args = if suite in ["spot-check", "all"], do: args ++ ["--fhir", "hapi"], else: args

    {output, exit} =
      System.cmd(System.find_executable("elixir"), args, cd: root, stderr_to_stdout: true)

    assert exit == 0, output

    assert %{"passed" => true, "skipped_required" => []} =
             e = File.read!(report) |> JSON.decode!()

    if suite in ["paired", "all"] do
      assert e["raw_payload_digests"] == e["oracle_payload_digests"]
      assert e["clock_holdout_violations"] == 0
      assert e["sibling_stall_audio_receipts"] > 0 and e["sibling_stall_heartbeats"] > 0
      assert e["bounds_respected"] and e["unknown_command_outcome_exercised"]
    end
  end
end
