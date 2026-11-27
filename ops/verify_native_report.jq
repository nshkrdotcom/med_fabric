# Report-level identity proof complements detached_artifacts.exs byte verification.
def hex($length): type == "string" and test("^[0-9a-f]{" + ($length|tostring) + "}$");
def package_identity:
  .key as $name | .value as $p |
  ($p | keys | sort) == ["build", "prepared", "sha256", "source_revision", "version"] and
  ($p.sha256 | hex(64)) and ($p.source_revision | hex(40)) and
  $p.version == (if $name == "med_ex" then "0.4.0" else "0.3.0" end) and
  (if $name == "med_ex" or $name == "mf_exam" then
    $p.build == "weld" and ($p.prepared | keys | sort) == ["identity", "release_sha256"] and
    ($p.prepared.identity | hex(64)) and ($p.prepared.release_sha256 | hex(64))
   else $p.build == "mix" and $p.prepared == null end);
def installed_evidence:
  . as $report | (.installed_artifacts | sort_by(.role)) as $installed |
  (.artifact_manifest_sha256 | hex(64)) and
  (.registry == "candidate" or .registry == "official") and
  .registry_origin.kind == .registry and
  (if .registry == "official" then .registry_origin.url == "https://repo.hex.pm"
   else (.registry_origin.url | type == "string" and
     (test("^https://[^/?#@[:space:]]+(/[^?#@[:space:]]*)?$") or
      test("^http://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?(/[^?#@[:space:]]*)?$")) and
     (test("^https://repo\\.hex\\.pm\\.?(:[0-9]+)?(/|$)"; "i") | not)) end) and
  ($installed | map(.role)) == ["exam", "handheld", "preview"] and
  (all($installed[];
    (.lock_sha256 | hex(64)) and
    (.packages | keys | sort) ==
      (if .role == "exam" then ["med_ex", "mf_exam"]
       elif .role == "handheld" then ["med_ex", "mf_handheld"]
       else ["med_ex", "med_ex_opus", "med_ex_rtc", "mf_preview"] end) and
    (all(.packages | to_entries[]; package_identity)))) and
  ([$installed[].packages | to_entries[]] | group_by(.key) |
    length == 6 and all(.[]; ([.[].value] | unique | length) == 1)) and
  ([$installed[].packages | to_entries[]] | unique_by(.key) |
    group_by(if .key | startswith("med_ex") then "sdk" else "fabric" end) |
    all(.[]; ([.[].value.source_revision] | unique | length) == 1));

def exact_coverage:
  (.spans + .gaps | sort) as $ordered |
  ([$ordered[] | select(.[0] >= .[1])] | length) == 0 and
  (reduce $ordered[] as $span (0; if . == $span[0] then $span[1] else error("noncontiguous coverage") end)) == .samples;

(if $ARGS.named.suite == "paired" then
  (.installed_artifacts == null or installed_evidence) else installed_evidence end) and
.schema == "medfabric.acceptance.v2" and
.runner == "elixir-native" and .passed == true and .skipped_required == [] and
(.required_suites | sort) ==
  (if $ARGS.named.suite == "paired" then ["paired"] else ["browser-microphone", "paired", "spot-check"] end) and
.bounds_respected and .raw_payload_digests == .oracle_payload_digests and
(.configured_limits == {pending_frames:16,pending_bytes:262144,spool_bytes:67108864,
  frame_bytes:65536,wire_frame_bytes:65584,metadata_records:100000}) and
(.measured_maxima | keys | sort) == (.configured_limits | keys | sort) and
.clock_holdout_violations == 0 and .duplicate_logical_frames == 0 and
.unknown_command_outcome_exercised and .command_mutations == 1 and
.monitor_checked_samples == 2880000 and .monitor_trace_digest == .monitor_oracle_trace_digest and
.sibling_stall_audio_receipts > 0 and .sibling_stall_lease_extension_ms > 0 and
.preview_role_isolation_verified and .preview_os_process_killed and
.scenarios.baseline.coverage.audio.samples == 2880000 and
.scenarios.baseline.coverage.ecg.samples == 15000 and
([.scenarios.baseline.clock_holdouts[] | .tested > 0 and .violations == 0] | all) and
(.scenarios as $s | ["local-monitor-stall", "local-monitor-kill", "local-monitor-startup"] |
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
  ["baseline", "local-monitor-startup", "local-monitor-stall", "local-monitor-kill", "local-monitor-stop", "source-gap", "multi-sequence-gap", "concurrent-encounter", "rational-s24", "accepted_before_durable", "durable_before_ack",
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
(.scenarios["browser-microphone"] | .actual_browser_playback and .encounter_scope and .recording)
end)
