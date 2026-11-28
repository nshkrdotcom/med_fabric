"""Report-verifier regressions; synthetic JSON is not native qualification evidence."""
import json
from pathlib import Path
import subprocess
import unittest

VERIFIER = Path(__file__).with_name('verify_soak_report.jq')


def report():
    limits = dict(frame_bytes=65536, wire_frame_bytes=65584, pending_bytes=262144,
                  pending_frames=16, spool_bytes=67108864, metadata_records=100000)
    timing = dict(count=20, p50_us=100, p95_us=200, p99_us=300, max_us=400)
    packages = {name: dict(version='0.4.0' if name == 'med_ex' else '0.3.0',
        sha256='a'*64, source_revision=('b' if name.startswith('med_ex') else 'c')*40,
        build='weld' if name in ('med_ex', 'mf_exam') else 'mix',
        prepared=dict(identity='d'*64, release_sha256='e'*64)
          if name in ('med_ex', 'mf_exam') else None)
        for name in ('med_ex', 'med_ex_opus', 'med_ex_rtc', 'mf_exam', 'mf_handheld', 'mf_preview')}
    roles = dict(exam=('med_ex', 'mf_exam'), handheld=('med_ex', 'mf_handheld'),
                 preview=('med_ex', 'med_ex_opus', 'med_ex_rtc', 'mf_preview'))
    installed = [dict(role=role, packages={name: packages[name] for name in names},
                      lock_sha256='f'*64) for role, names in roles.items()]
    return dict(installed_artifacts=installed, artifact_manifest_sha256='9'*64,
                registry='candidate', registry_origin=dict(kind='candidate', url='https://candidate.example.test'),
                schema='medfabric.acceptance.v2' , runner='elixir-native', passed=True,
                required_suites=['soak'], skipped_required=[], bounds_respected=True,
                configured_limits=limits, measured_maxima=dict(limits),
                scenarios=dict(soak=dict(requested_seconds=1740, stage='complete',
                    client_exit=0, progress=dict(state='promoted'),
                    streams=dict(audio=dict(samples=83520000), ecg=dict(samples=435000)),
                    raw_payload_digests=dict(audio='a'*64, ecg='b'*64),
                    oracle_payload_digests=dict(audio='a'*64, ecg='b'*64),
                    performance=dict(failures=[], sustained_lag_check_possible=True,
                        policy=dict(sample_interval_ms=5000, warmup_ms=10000, startup_budget_ms=15000,
                                    lag_budget_ms=2000, consecutive_limit=2),
                        sampled_timings=[dict(timing, stream=stream, stage=stage)
                            for stream in ("audio", "ecg") for stage in ("checkpoint", "writer_checkpoint")]),
                    reclamation=dict(source_records=100, visits=110, max_visits=200),
                    preview=dict(enabled=False))))


class SoakReportTest(unittest.TestCase):
    def check(self, value, accepted, preview='off'):
        result = subprocess.run(['jq', '-e', '--arg', 'preview', preview,
                                 '-f', str(VERIFIER)], input=json.dumps(value),
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode == 0, accepted, result.stdout+result.stderr)

    def test_exact_clean_shape_and_both_preview_modes(self):
        value = report()
        self.check(value, True)
        self.check(value, False, 'isolated')
        value['preview_role_isolation_verified'] = True
        value['scenarios']['soak']['preview'] = dict(stopped=True, elapsedMs=1710000,
            observations=[dict(connected=True, decodedSamples=1000, elapsedMs=0),
                          dict(connected=True, decodedSamples=49000, elapsedMs=1000)])
        self.check(value, True, 'isolated')
        value['scenarios']['soak']['preview']['observations'][1]['decodedSamples'] = 1000
        self.check(value, False, 'isolated')

    def test_short_duration_and_weakened_performance_policy_are_not_full_gates(self):
        for key, value in [('requested_seconds', 60), ('client_exit', 1)]:
            changed = report(); changed['scenarios']['soak'][key] = value
            self.check(changed, False)
        for key, value in [('lag_budget_ms', 2001), ('consecutive_limit', 3), ('startup_budget_ms', 15001)]:
            changed = report(); changed['scenarios']['soak']['performance']['policy'][key] = value
            self.check(changed, False)

    def test_missing_measurements_cannot_pass_vacuous_all(self):
        for value in [None, {}, {'frame_bytes': 1}]:
            changed = report(); changed['measured_maxima'] = value
            self.check(changed, False)
        changed = report(); changed['configured_limits']['pending_frames'] = 1000
        self.check(changed, False)

    def test_missing_or_inconsistent_installed_identity_refuses(self):
        changed = report(); del changed['installed_artifacts']
        self.check(changed, False)
        changed = report(); changed['installed_artifacts'][0]['packages']['med_ex']['version'] = '0.3.1'
        self.check(changed, False)
        changed = report(); changed['installed_artifacts'][0]['packages']['mf_exam']['prepared'] = None
        self.check(changed, False)
        changed = report(); changed['artifact_manifest_sha256'] = 'unverified'
        self.check(changed, False)
        for url in ['https://repo.hex.pm/', 'https://repo.hex.pm', 'https://REPO.HEX.PM./path', 'https://repo.hex.pm:443', 'https://user:secret@candidate.test',
                    'https://candidate.test/?key=secret', 'http://remote.test']:
            changed = report(); changed['registry_origin']['url'] = url
            self.check(changed, False)
        changed = report(); changed['registry'] = 'official'
        changed['registry_origin'] = dict(kind='official', url='https://repo.hex.pm')
        self.check(changed, True)
        changed['registry_origin']['kind'] = 'candidate'
        self.check(changed, False)

    def test_new_diagnostics_cannot_replace_a_missing_checkpoint_series(self):
        changed = report()
        changed['scenarios']['soak']['performance']['sampled_timings'][0]['stage'] = 'frame_scope'
        self.check(changed, False)

    def test_wrong_source_bytes_or_unbounded_reclaim_refuse(self):
        changed = report(); changed['scenarios']['soak']['oracle_payload_digests']['audio'] = 'c'*64
        self.check(changed, False)
        changed = report(); changed['scenarios']['soak']['reclamation']['visits'] = 201
        self.check(changed, False)
        changed = report(); changed['scenarios']['soak']['streams']['audio']['samples'] -= 1
        self.check(changed, False)


if __name__ == '__main__':
    unittest.main()
