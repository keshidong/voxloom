from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("release-version.py")


class ReleaseVersionTest(unittest.TestCase):
    def test_merged_commit_gets_the_next_patch_and_reuses_its_tag_on_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)

            def git(*args):
                subprocess.run(["git", "-c", "user.name=Release Test", "-c", "user.email=test@example.invalid", *args],
                               check=True, cwd=repo, capture_output=True)

            def version():
                return subprocess.check_output([sys.executable, SCRIPT], cwd=repo, text=True).strip()

            git("init", "--quiet")
            git("commit", "--quiet", "--allow-empty", "-m", "Previous release")
            self.assertEqual(version(), "v0.1.0")
            git("tag", "v0.9.15")
            git("tag", "-a", "v0.10.9", "-m", "Existing release")
            git("tag", "v0.10.11-rc.1")
            git("commit", "--quiet", "--allow-empty", "-m", "Merge a pull request")
            self.assertEqual(version(), "v0.10.10")

            git("tag", "-a", "v0.10.10", "-m", "Reserved for this commit")
            git("tag", "v0.10.11", "HEAD^")
            self.assertEqual(version(), "v0.10.10")
