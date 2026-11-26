"""Test native-runner source selection without starting services or the BEAM."""

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

        releases = self.root / "_build/foundation-release-evidence/weld/med_ex"
        identity = "a" * 64
        self.candidate = releases / identity / "project"
        self.candidate.mkdir(parents=True)
        (self.candidate / "mix.exs").write_text("# Old candidate fixture\n")
        (releases / "CURRENT").write_text(f"weld.release/v1 {identity}\n")
        self.volume = self.root / "volume"
        self.volume.mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        self.log = self.root / "calls.log"

        # Replace only external service/tool boundaries. The actual runner's
        # argument parsing, stale-pointer selection and environment are used.
        scripts = {
            "pg_config": '#!/bin/sh\nprintf "%s\\n" "$QC_TEST_TOOLS"\n',
            "findmnt": "#!/bin/sh\nprintf 'fixture filesystem\\n'\n",
            "mix": """#!/bin/sh
set -eu
if [ "$QC_TEST_MODE" = default ]; then
  test -z "${MF_MED_EX_PATH:-}" || exit 91
  test "${MF_SOURCE_QC_EXPECT_DEFAULT:-}" = 1 || exit 92
else
  test "${MF_MED_EX_PATH:-}" = "$QC_TEST_PROJECT" || exit 93
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


if __name__ == "__main__":
    unittest.main()
