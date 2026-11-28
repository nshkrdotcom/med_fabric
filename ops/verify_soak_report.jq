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

installed_evidence and
.schema == "medfabric.acceptance.v2" and .runner == "elixir-native" and
.passed == true and .required_suites == ["soak"] and .skipped_required == [] and
.bounds_respected == true and
(.measured_maxima | keys | sort) == (.configured_limits | keys | sort) and
(.configured_limits | keys | sort) ==
  ["frame_bytes", "metadata_records", "pending_bytes", "pending_frames", "spool_bytes", "wire_frame_bytes"] and
.configured_limits.frame_bytes == 65536 and .configured_limits.wire_frame_bytes == 65584 and
.configured_limits.pending_bytes == 262144 and .configured_limits.pending_frames == 16 and
.configured_limits.spool_bytes == 67108864 and .configured_limits.metadata_records == 100000 and
(.configured_limits as $limits | [.measured_maxima | to_entries[] |
  (.value | type) == "number" and .value >= 0 and .value <= $limits[.key]] | all) and
(.scenarios.soak as $soak |
  $soak.requested_seconds == 1740 and $soak.stage == "complete" and
  $soak.client_exit == 0 and $soak.progress.state == "promoted" and
  $soak.streams.audio.samples == 83520000 and $soak.streams.ecg.samples == 435000 and
  $soak.raw_payload_digests == $soak.oracle_payload_digests and
  ($soak.raw_payload_digests | keys | sort) == ["audio", "ecg"] and
  $soak.performance.failures == [] and $soak.performance.sustained_lag_check_possible and
  $soak.performance.policy.sample_interval_ms == 5000 and
  $soak.performance.policy.warmup_ms == 10000 and
  $soak.performance.policy.startup_budget_ms == 15000 and
  $soak.performance.policy.lag_budget_ms == 2000 and
  $soak.performance.policy.consecutive_limit == 2 and
  ([$soak.performance.sampled_timings[] | [.stream, .stage]] as $observed |
    ([("audio", "ecg") as $stream | ("checkpoint", "writer_checkpoint") | [$stream, .]] - $observed | length) == 0) and
  ([$soak.performance.sampled_timings[] |
    .count > 0 and .p50_us >= 0 and .p95_us >= .p50_us and
    .p99_us >= .p95_us and .max_us >= .p99_us] | all) and
  $soak.reclamation.source_records > 0 and
  $soak.reclamation.visits >= $soak.reclamation.source_records and
  $soak.reclamation.max_visits == ($soak.reclamation.source_records * 2) and
  $soak.reclamation.visits <= $soak.reclamation.max_visits and
  (if $preview == "isolated" then
    .preview_role_isolation_verified == true and $soak.preview.stopped == true and
    $soak.preview.elapsedMs >= 1700000 and
    ($soak.preview.observations | length) >= 2 and
    (all($soak.preview.observations[]; .connected == true and .decodedSamples > 0)) and
    (reduce $soak.preview.observations[] as $point
      ({previous: null, valid: true};
       .valid = (.valid and (.previous == null or
         ($point.elapsedMs > .previous.elapsedMs and
          $point.decodedSamples > .previous.decodedSamples))) |
       .previous = $point) | .valid)
   else $preview == "off" and $soak.preview.enabled == false end))
