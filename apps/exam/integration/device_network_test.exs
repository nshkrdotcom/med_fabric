defmodule MedFabric.DeviceNetworkTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 1_550_000

  test "external paired and spot-check producers verify real durable artifacts and reviewed outcomes" do
    root = Path.expand("../../..", __DIR__)

    run =
      Path.join(
        System.tmp_dir!(),
        "fabric-network-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    report = Path.join(run, "report.json")
    suite = System.get_env("MF_NETWORK_SUITE", "paired")

    args = [
      "ops/handheld_acceptance.exs",
      "--suite",
      suite,
      "--run-dir",
      run,
      "--report",
      report,
      "--preview",
      System.get_env("MF_NETWORK_PREVIEW", "off")
    ]

    args = if suite in ["spot-check", "all"], do: args ++ ["--fhir", "hapi"], else: args

    {_output, exit} =
      System.cmd(System.find_executable("elixir"), args, cd: root, stderr_to_stdout: true)

    assert exit == 0, "Inspect retained report #{report}"

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
