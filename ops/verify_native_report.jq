def exact_coverage:
  (.spans + .gaps | sort) as $ordered |
  ([$ordered[] | select(.[0] >= .[1])] | length) == 0 and
  (reduce $ordered[] as $span (0; if . == $span[0] then $span[1] else error("noncontiguous coverage") end)) == .samples;

.runner == "elixir-native" and .passed and .skipped_required == [] and
(.required_suites | sort) ==
  (if $ARGS.named.suite == "paired" then ["paired"] else ["legacy-browser", "paired", "spot-check"] end) and
.bounds_respected and .raw_payload_digests == .oracle_payload_digests and
.clock_holdout_violations == 0 and .duplicate_logical_frames == 0 and
.unknown_command_outcome_exercised and .command_mutations == 1 and
.monitor_checked_samples == 2880000 and .monitor_trace_digest == .monitor_oracle_trace_digest and
.sibling_stall_audio_receipts > 0 and .sibling_stall_heartbeats > 0 and
.preview_role_isolation_verified and .preview_os_process_killed and
.scenarios.baseline.coverage.audio.samples == 2880000 and
.scenarios.baseline.coverage.ecg.samples == 15000 and
([.scenarios.baseline.clock_holdouts[] | .tested > 0 and .violations == 0] | all) and
(.scenarios as $s | ["local-monitor-stall", "local-monitor-kill"] |
  all(.[]; $s[.].coverage.audio.samples == 288000 and $s[.].coverage.ecg.samples == 1500)) and
.scenarios.baseline.browser_review_verified and
.scenarios["source-gap"].browser_review_verified and
.scenarios["source-gap"].coverage.audio.gaps == [[1920, 2020]] and
.scenarios["multi-sequence-gap"].coverage.audio.gaps == [[1920, 2220]] and
.scenarios["concurrent-encounter"].coverage.audio.samples == 2880000 and
.scenarios["concurrent-encounter"].coverage.ecg.samples == 15000 and
.scenarios["rational-s24"].coverage.audio.samples == 89 and
.scenarios["source-reset"].coverage.ecg.samples == 75 and
.scenarios["source-reset"].review_decision == "repeat" and
.scenarios["spool-capacity"].coverage != null and
(.configured_limits as $limit | [.measured_maxima | to_entries[] | .value <= $limit[.key]] | all) and
(.scenarios as $cases |
  ["baseline", "local-monitor-stall", "local-monitor-kill", "local-monitor-stop", "source-gap", "multi-sequence-gap", "concurrent-encounter", "rational-s24", "accepted_before_durable", "durable_before_ack",
   "journal_sync", "after_object_install", "manifest_install", "db_completion", "spool-capacity",
   "source-reset", "handheld-restart"] |
  map($cases[.] | .raw_payload_digests == .oracle_payload_digests and
      .duplicate_logical_frames == 0 and ([.coverage[] | exact_coverage] | all)) | all) and
([.processes[] | select(.name == "exam-mix" and .exit == 137)] | length) >= (if $ARGS.named.suite == "paired" then 5 else 6 end) and
([.processes[] | select(.name == "preview-mix" and .exit == 137)] | length) >= 1 and
([.processes[] | select(.name == "handheld-mix" and .exit == 137)] | length) >= 1 and
.scenarios.manifest_install.staged_bytes_preserved and
.scenarios.db_completion.staged_bytes_preserved and
(.scenarios["network-denials"].checked |
  sort == ["competing_producer","conflicting_replay","descriptor_mismatch","duplicate_json","mismatched_epoch","nonzero_epoch",
           "stale_generation","swapped_number","wrong_encounter"]) and
.scenarios["handheld-restart"].second_owner_refused and
(.scenarios["handheld-restart"] | .coverage.audio.samples == .synchronized_cutoffs.audio and
  .coverage.ecg.samples == .synchronized_cutoffs.ecg) and
(if .required_suites == ["paired"] then true else
(.scenarios.plx | .local_ingestion_before_ack and .committed_event_replayed and
  .early_final_inventory and .actual_hapi_loss_readback and (.event_ids | unique | length) == 2) and
(.fhir_external_ids | length == 2 and ([.[].remote] | unique | length) == 2) and
(.scenarios["legacy-browser"] | .actual_browser_playback and .encounter_scope and .recording)
end)
