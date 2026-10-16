"""Git hook contract tests. No Unreal Engine or PowerShell installation required."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1]


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()


class HookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='unrealsync hook test ')
        self.addCleanup(self.temp.cleanup)
        self.repo = pathlib.Path(self.temp.name) / 'repo'
        self.repo.mkdir()
        git(self.repo, 'init', '-b', 'main')
        git(self.repo, 'config', 'user.name', 'Test')
        git(self.repo, 'config', 'user.email', 'test@example.com')
        hooks = self.repo / '.githooks'
        hooks.mkdir()
        for name in ('post-merge', 'post-rewrite'):
            data = (SOURCE / 'hooks' / name).read_bytes()
            dest = hooks / name
            dest.write_bytes(data)
            dest.chmod(0o755)
        tool = self.repo / '.unrealsync'
        tool.mkdir()
        (tool / 'UnrealSync.ps1').write_text('placeholder')
        (self.repo / 'seed.txt').write_text('initial')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-m', 'initial')
        git(self.repo, 'config', 'core.hooksPath', '.githooks')
        fake_bin = pathlib.Path(self.temp.name) / 'bin'
        fake_bin.mkdir()
        fake = fake_bin / 'powershell.exe'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$UNREALSYNC_TEST_LOG"\n')
        fake.chmod(0o755)
        self.hook_log = pathlib.Path(self.temp.name) / 'calls.log'
        self.saved_path = os.environ['PATH']
        self.saved_log = os.environ.get('UNREALSYNC_TEST_LOG')
        os.environ['PATH'] = f'{fake_bin}{os.pathsep}{self.saved_path}'
        os.environ['UNREALSYNC_TEST_LOG'] = str(self.hook_log)
        self.addCleanup(self.restore_env)

    def restore_env(self):
        os.environ['PATH'] = self.saved_path
        if self.saved_log is None:
            os.environ.pop('UNREALSYNC_TEST_LOG', None)
        else:
            os.environ['UNREALSYNC_TEST_LOG'] = self.saved_log

    def test_fast_forward_merge_invokes_auto_mode(self):
        git(self.repo, 'switch', '-c', 'feature')
        (self.repo / 'code.cpp').write_text('int main() { return 0; }')
        git(self.repo, 'add', 'code.cpp')
        git(self.repo, 'commit', '-m', 'code')
        git(self.repo, 'switch', 'main')
        git(self.repo, 'merge', '--ff-only', 'feature')
        calls = self.hook_log.read_text()
        self.assertIn('-Mode Auto', calls)
        self.assertIn('-OldRevision', calls)
        self.assertIn('-NewRevision', calls)

    def test_merge_into_feature_invokes_auto_mode(self):
        git(self.repo, 'switch', '-c', 'feature')
        (self.repo / 'feature.txt').write_text('work')
        git(self.repo, 'add', 'feature.txt')
        git(self.repo, 'commit', '-m', 'feature')
        git(self.repo, 'switch', 'main')
        (self.repo / 'from-main.cpp').write_text('int a = 1;')
        git(self.repo, 'add', 'from-main.cpp')
        git(self.repo, 'commit', '-m', 'main code')
        git(self.repo, 'switch', 'feature')
        git(self.repo, 'merge', 'main', '--no-edit')
        self.assertIn('-Mode Auto', self.hook_log.read_text())

    def test_completed_rebase_invokes_auto_mode(self):
        git(self.repo, 'switch', '-c', 'feature')
        (self.repo / 'feature.txt').write_text('work')
        git(self.repo, 'add', 'feature.txt')
        git(self.repo, 'commit', '-m', 'feature')
        git(self.repo, 'switch', 'main')
        (self.repo / 'from-main.cpp').write_text('int a = 1;')
        git(self.repo, 'add', 'from-main.cpp')
        git(self.repo, 'commit', '-m', 'main code')
        git(self.repo, 'switch', 'feature')
        git(self.repo, 'rebase', 'main')
        self.assertIn('-Mode Auto', self.hook_log.read_text())

    def test_no_new_changes_does_not_invoke_hook(self):
        git(self.repo, 'merge', 'main')
        self.assertFalse(self.hook_log.exists())


if __name__ == '__main__':
    unittest.main()
