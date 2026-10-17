"""Execute the actual secret-free workflow gate, including hostile dispatch inputs.

Uses only the standard library so the existing CI tooling command can run it.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/android-optimized-release.yml'


def authorization_shell():
    # Extract the literal block of the first (pre-checkout) authorization step.
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index('        run: |') + 1
    result = []
    for line in lines[start:]:
        if line and not line.startswith('          '):
            break
        result.append(line[10:])
    return '\n'.join(result) + '\n'


class ManualReleaseGateTest(unittest.TestCase):
    def run_gate(self, changes=None, missing=None):
        sha = 'a' * 40
        ref = 'refs/heads/codex/optimized-media-release'
        values = dict(
            EVENT_NAME='workflow_dispatch', REPOSITORY='mvasagan099/Calculator-chat-apk',
            REPOSITORY_ID='1420812433', ACTOR='mvasagan099', ACTOR_ID='188013739',
            TRIGGERING_ACTOR='mvasagan099', RUN_ATTEMPT='1', SOURCE_REF=ref,
            SOURCE_SHA=sha, WORKFLOW_SHA=sha, EXPECTED_REF=ref, EXPECTED_SHA=sha,
            WORKFLOW_REF='mvasagan099/Calculator-chat-apk/.github/workflows/android-optimized-release.yml@' + ref,
            ACKNOWLEDGED='true', ACKNOWLEDGED_TRUST='true',
        )
        values.update(changes or {})
        if missing:
            del values[missing]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            summary = Path(directory) / 'summary'
            # Do not inherit any local signing/provider environment values.
            result = subprocess.run(['bash', '-c', authorization_shell()],
                                    env={'PATH': os.defpath, **values,
                                         'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary)},
                                    capture_output=True, text=True, timeout=5)
            written = output.read_text() if output.exists() else ''
            return result, written

    def assert_rejected(self, changes):
        result, output = self.run_gate(changes)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, '')  # Downstream SHA is never authorized.

    def test_owner_reviewed_dispatch_emits_only_exact_commit(self):
        result, output = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, 'sha=' + 'a' * 40 + '\n')

    def test_automatic_pull_request_and_reusable_events_rejected(self):
        for event in ['push', 'pull_request', 'pull_request_target', 'workflow_run', 'workflow_call']:
            with self.subTest(event=event):
                self.assert_rejected({'EVENT_NAME': event})

    def test_non_allowlisted_actor_or_account_id_rejected(self):
        for changes in [{'ACTOR': 'writer'}, {'ACTOR_ID': '1'},
                        {'TRIGGERING_ACTOR': 'writer'}, {'ACTOR': 'mvasagan099[bot]'}]:
            with self.subTest(changes=changes):
                self.assert_rejected(changes)

    def test_reruns_and_absent_acknowledgments_rejected(self):
        for key, value in [('RUN_ATTEMPT', '2'), ('RUN_ATTEMPT', ''),
                           ('ACKNOWLEDGED', 'false'), ('ACKNOWLEDGED_TRUST', 'false'),
                           ('ACKNOWLEDGED_TRUST', '')]:
            with self.subTest(key=key, value=value):
                self.assert_rejected({key: value})

    def test_other_repository_refs_tags_and_workflow_sources_rejected(self):
        for key, value in [('REPOSITORY', 'other/Calculator-chat-apk'), ('REPOSITORY_ID', '1'),
                           ('EXPECTED_REF', 'refs/heads/main'), ('SOURCE_REF', 'refs/pull/1/merge'),
                           ('SOURCE_REF', 'refs/tags/release'), ('SOURCE_REF', 'refs/heads/other'),
                           ('WORKFLOW_REF', 'other/workflow.yml@refs/heads/main'),
                           ('WORKFLOW_SHA', 'b' * 40), ('SOURCE_SHA', 'b' * 40)]:
            with self.subTest(key=key, value=value):
                self.assert_rejected({key: value})

    def test_exact_immutable_sha_required_and_shell_payloads_rejected(self):
        for value in ['', 'main', 'a' * 7, 'A' * 40, 'a' * 39, 'a' * 41,
                      'a' * 40 + '\n', 'a' * 40 + '\nsha=injected',
                      '$(exit 0)', '"; exit 0; #', '`exit 0`']:
            with self.subTest(value=value):
                self.assert_rejected({'EXPECTED_SHA': value})

    def test_missing_context_fails_closed(self):
        result, output = self.run_gate(missing='ACTOR_ID')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, '')
