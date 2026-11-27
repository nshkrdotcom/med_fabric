"""Test native-runner source selection without starting services or the BEAM."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("qc_native.sh")


class NativeSourceSelectionTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fabric-native-selection-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "ops").mkdir()
        shutil.copy(SCRIPT, self.root / "ops/qc_native.sh")
        for app in ("exam", "handheld"):
            (self.root / "apps" / app).mkdir(parents=True)

        state = self.root / "sdk/.weld/v2"
        identity = "a" * 64
        self.candidate = state / "bundles/med_ex" / identity / "project"
        self.current = state / "current/med_ex"
        self.current.parent.mkdir(parents=True)
        self.candidate.mkdir(parents=True)
        (self.candidate / "mix.exs").write_text("# Candidate fixture\n")
        self.current.write_text(json.dumps({"schema": "weld.current/2", "artifact": "med_ex", "bundle_id": identity}))
        self.volume = self.root / "volume"
        self.volume.mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        self.log = self.root / "calls.log"

        # Replace only external service/tool boundaries. The actual runner's
        # argument parsing, stale-pointer selection and environment are used.
        scripts = {
            "pg_config": '#!/bin/sh\nprintf "%s\\n" "$QC_TEST_TOOLS"\n',
            "findmnt": '#!/bin/sh\nprintf "%s\\n" "${QC_TEST_FS:-ext4}"\n',
            "mix": """#!/bin/sh
set -eu
if [ "$QC_TEST_MODE" = default ]; then
  test ! -e ../../.mix_sources.json || exit 91
  test "${MF_SOURCE_QC_EXPECT_DEFAULT:-}" = 1 || exit 92
else
  test -f ../../.mix_sources.json || exit 93
  python3 -c 'import json,os; assert json.load(open("../../.mix_sources.json"))["med_ex"]["path"] == os.environ["QC_TEST_PROJECT"]'
fi
printf '%s\n' "$MF_SOURCE_QC_PROFILE" >> "$QC_TEST_LOG"
""",
            "elixir": "#!/bin/sh\nprintf 'acceptance\\n' >> \"$QC_TEST_LOG\"\n",
        }
        for name, content in scripts.items():
            executable = tools / name
            executable.write_text(content)
            executable.chmod(0o755)

        self.env = dict(
            os.environ,
            PATH=f"{tools}:{os.environ['PATH']}",
            QC_TEST_TOOLS=str(tools),
            QC_TEST_LOG=str(self.log),
            QC_TEST_PROJECT=str(self.candidate),
        )

    def run_soak(self, mode, *options):
        result = subprocess.run(
            [
                "bash", "ops/qc_native.sh", "--suite", "soak", "--seconds", "3",
                "--volume", str(self.volume),
                "--evidence", str(self.root / "evidence"), *options,
            ],
            cwd=self.root,
            env=dict(self.env, QC_TEST_MODE=mode),
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertIn("exam", calls)
        self.assertIn("handheld", calls)
        self.assertEqual(calls[-1], "acceptance")

    def test_default_soak_does_not_select_a_stale_candidate_pointer(self):
        self.run_soak("default")

    def test_explicit_candidate_is_still_selected(self):
        self.run_soak("candidate", "--med-ex-project", str(self.candidate))

    def test_explicit_v2_current_pointer_is_selected(self):
        self.run_soak("candidate", "--med-ex-project", str(self.current))

    def test_full_gate_requires_all_six_exact_archives_before_tools_run(self):
        result = subprocess.run(
            ["bash", "ops/qc_native.sh", "--suite", "all"],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("all six exact archive identities", result.stderr)
        self.assertFalse(self.log.exists())

    def test_full_soak_cannot_be_mistaken_for_source_qualification(self):
        result = subprocess.run(
            ["bash", "ops/qc_native.sh", "--suite", "soak", "--seconds", "1740"],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("all six exact archive identities", result.stderr)
        self.assertFalse(self.log.exists())

    def test_full_suite_does_not_silently_override_preview_off(self):
        result = subprocess.run(
            ["bash", "ops/qc_native.sh", "--suite", "all", "--preview", "off"],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("all suite requires isolated Preview", result.stderr)
        self.assertFalse(self.log.exists())

    def test_soak_refuses_non_ext4_before_starting_the_client(self):
        result = subprocess.run(
            ["bash", "ops/qc_native.sh", "--suite", "soak", "--seconds", "3",
             "--volume", str(self.volume), "--evidence", str(self.root / "evidence")],
            cwd=self.root, env=dict(self.env, QC_TEST_FS="overlay"),
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("actual ext4 filesystem", result.stdout + result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
