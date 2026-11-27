Code.require_file("support/fixtures.exs", __DIR__)

defmodule MedFabric.DeviceNetworkTest do
  use ExUnit.Case, async: false

  setup context, do: MedFabric.Exam.IntegrationFixtures.trusted_tmp(context)
  @moduletag timeout: 1_550_000

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

    elixir =
      System.find_executable("elixir") || flunk("The native acceptance runner requires Elixir")

    {output, exit} = System.cmd(elixir, args, cd: root, stderr_to_stdout: true)

    assert exit == 0, output

    assert %{"passed" => true, "skipped_required" => [], "runner" => "elixir-native"} =
             e = File.read!(report) |> JSON.decode!()

    if suite in ["paired", "all"] do
      assert e["raw_payload_digests"] == e["oracle_payload_digests"]
      assert e["clock_holdout_violations"] == 0
      assert e["sibling_stall_audio_receipts"] > 0 and e["sibling_stall_heartbeats"] > 0
      assert e["bounds_respected"] and e["unknown_command_outcome_exercised"]
      assert e["monitor_trace_digest"] == e["monitor_oracle_trace_digest"]
      assert e["scenarios"]["handheld-restart"]["second_owner_refused"]

      if System.get_env("MF_NETWORK_PREVIEW") == "isolated" do
        assert e["preview_os_process_killed"] and e["preview_role_isolation_verified"]
      end
    end

    if suite in ["spot-check", "all"] do
      assert e["scenarios"]["plx"]["local_ingestion_before_ack"]
      assert e["scenarios"]["plx"]["committed_event_replayed"]
      assert length(e["fhir_external_ids"]) == 2
    end

    if suite in ["browser", "all"],
      do: assert(e["scenarios"]["browser"]["actual_browser_playback"])
  end
end
