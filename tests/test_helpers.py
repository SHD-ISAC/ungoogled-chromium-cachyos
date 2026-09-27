"""Offline regression tests; never start Docker or download Chromium."""
import fcntl
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(r"^pkgver=(.+)$", (ROOT / "PKGBUILD").read_text(), re.M)[1]
RELEASE = re.search(r"^pkgrel=(.+)$", (ROOT / "PKGBUILD").read_text(), re.M)[1]
PACKAGE_VERSION = f"{VERSION}-{RELEASE}"
MARKER = ".ungoogled-chromium-cache-complete"


class Helpers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.log = self.work / "commands"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_LOG=str(self.log), CHROMIUM_SOURCE_CACHE="",
                        CHROMIUM_CACHE_DIR=str(self.work / "cache"))
        self.env.pop("GITHUB_OUTPUT", None)
        self.env.pop("GIT_CONFIG_COUNT", None)
        self.mock("sleep", "exit 0")

    def mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, script, *args, env=None):
        return subprocess.run(["bash", str(ROOT / script), *map(str, args)],
                              cwd=self.work, env=env or self.env,
                              text=True, capture_output=True, timeout=15)

    def cache(self, version=VERSION, parent=None):
        parent = parent or self.work / "source-cache"
        source = parent / f"chromium-{VERSION}"
        (source / "chrome").mkdir(parents=True)
        (source / MARKER).touch()
        (source / "DEPS").write_text("# fixture\n")
        (source / "chrome/VERSION").write_text("".join(
            f"{key}={value}\n" for key, value in
            zip(("MAJOR", "MINOR", "BUILD", "PATCH"), version.split("."))))
        self.env["CHROMIUM_SOURCE_CACHE"] = str(parent)
        return source

    def test_cache_copy_preserves_cache_and_removes_marker_from_worktree(self):
        source = self.cache()
        self.mock("git", "exit 99")
        result = self.run_script("fetch-chromium-release", VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((source / MARKER).exists())
        self.assertFalse((self.work / f"chromium-{VERSION}" / MARKER).exists())
        self.assertTrue((self.work / f"chromium-{VERSION}/DEPS").exists())

    def test_cache_version_mismatch_is_rejected(self):
        self.cache("1.2.3.4")
        result = self.run_script("fetch-chromium-release", VERSION)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / f"chromium-{VERSION}").exists())

    def test_existing_destination_is_never_nested_or_overwritten(self):
        self.cache()
        destination = self.work / f"chromium-{VERSION}"
        destination.mkdir()
        (destination / "valuable").write_text("keep")
        result = self.run_script("fetch-chromium-release", VERSION)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(destination.iterdir()), [destination / "valuable"])

    def test_failed_cache_copy_does_not_publish_partial_tree(self):
        self.cache()
        self.mock("cp", 'touch "${@: -1}/partial"; exit 28')
        result = self.run_script("fetch-chromium-release", VERSION)
        self.assertEqual(result.returncode, 28)
        self.assertFalse((self.work / f"chromium-{VERSION}").exists())
        self.assertEqual(list(self.work.glob(".chromium-*.copy.*")), [])

    def test_clone_exhaustion_preserves_nonzero_exit_code(self):
        self.mock("git", 'echo "$*" >> "$TEST_LOG"; exit 23')
        result = self.run_script("fetch-chromium-release", VERSION)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()), 5)

    def test_resume_pins_requested_tag_and_preserves_git_environment(self):
        checkout = self.work / "chromium-checkout"
        source = checkout / "src"
        (checkout / "depot_tools/.git").mkdir(parents=True)
        source.mkdir()
        def git(*args):
            return subprocess.run(["git", "-C", str(source), *args], check=True,
                                  capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        (source / "fixture").write_text("release")
        git("add", ".")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-qm", "release")
        git("tag", VERSION)
        release = git("rev-parse", "HEAD")
        (source / "fixture").write_text("unrelated newer commit")
        git("add", ".")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "commit", "-qm", "later")
        self.env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.proxy",
                        GIT_CONFIG_VALUE_0="http://fixture.invalid")
        self.mock("gclient", 'printf "%s|%s|%s|%s\\n" "$*" "$GIT_CONFIG_COUNT" '
                  '"$GIT_CONFIG_KEY_0" "$GIT_CONFIG_VALUE_0" >> "$TEST_LOG"; exit 29')
        result = self.run_script("fetch-chromium-release", VERSION)
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertEqual(git("rev-parse", "HEAD"), release)
        lines = self.log.read_text().splitlines()
        self.assertEqual(len(lines), 5)
        self.assertIn(f"--revision src@{VERSION}|3|http.proxy|http://fixture.invalid", lines[0])

    def test_invalid_versions_are_rejected_before_side_effects(self):
        for version in ("", "../unsafe", "153.0.1", "1.2.3.4\nextra"):
            for script in ("fetch-chromium-release", "prefetch-chromium.sh"):
                if not version and script == "prefetch-chromium.sh":
                    continue  # Empty means the PKGBUILD default here.
                result = self.run_script(script, version)
                self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "cache").exists())

    def test_custom_prefetch_cache_base_is_used_without_docker(self):
        self.cache(parent=self.work / "cache/chromium-source")
        self.mock("docker", 'echo unexpected >> "$TEST_LOG"; exit 99')
        result = self.run_script("prefetch-chromium.sh", VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_prefetch_lock_prevents_shared_dependency_cache_races(self):
        git_cache = self.work / "cache/git-cache"
        git_cache.mkdir(parents=True)
        with (git_cache / ".prefetch.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("prefetch-chromium.sh", VERSION)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another prefetch", result.stderr)

    def test_completed_staging_tree_can_be_published_after_interruption(self):
        stage = self.work / f"cache/chromium-source/.prefetch-{VERSION}"
        self.cache(parent=stage)
        self.mock("docker", '[[ $1 == rm ]] || exit 99')
        result = self.run_script("prefetch-chromium.sh", VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / f"cache/chromium-source/chromium-{VERSION}" / MARKER).exists())

    def test_container_failure_is_reported_and_cleaned_up(self):
        self.mock("docker", '''echo "$*" >> "$TEST_LOG"
case "$1" in
    pull|rm) exit 0 ;;
    image) echo sha256:fixture ;;
    run) echo 'compiler failed'; exit 37 ;;
    *) exit 99 ;;
esac''')
        self.env["CACHYOS_OUTPUT_DIR"] = str(self.work / "output")
        result = self.run_script("cachyos-build.sh")
        self.assertEqual(result.returncode, 37, result.stderr)
        commands = self.log.read_text()
        self.assertIn(f"{self.work}/cache/chromium-source:/source-cache:ro", commands)
        self.assertIn("CHROMIUM_BUILD_JOBS=8", commands)
        self.assertIn("rm -f ungoogled-chromium-build-", commands)
        self.assertIn("compiler failed", (self.work / "output/build.log").read_text())

    def test_invalid_job_limit_cannot_enable_unlimited_ninja(self):
        for value in ("0", "-1", "8 -k0", "2\nextra"):
            self.env["CHROMIUM_BUILD_JOBS"] = value
            result = self.run_script("cachyos-build.sh")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("positive integer", result.stderr)

    def test_cancellation_removes_running_container(self):
        self.env["CACHYOS_OUTPUT_DIR"] = str(self.work / "output")
        self.env["PID_FILE"] = str(self.work / "container.pid")
        self.mock("docker", '''echo "$*" >> "$TEST_LOG"
case "$1" in
    pull) exit 0 ;;
    image) echo sha256:fixture ;;
    run) echo $$ > "$PID_FILE"; exec /bin/sleep 30 ;;
    rm) kill "$(cat "$PID_FILE")" ;;
    *) exit 99 ;;
esac''')
        process = subprocess.Popen(["bash", str(ROOT / "cachyos-build.sh")],
                                   cwd=self.work, env=self.env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not Path(self.env["PID_FILE"]).exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(Path(self.env["PID_FILE"]).exists())
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assertIn("rm -f ungoogled-chromium-build-", self.log.read_text())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def package(self, *, name="ungoogled-chromium", version=PACKAGE_VERSION,
                arch="x86_64_v4", duplicate=False):
        path = self.work / f"ungoogled-chromium-{PACKAGE_VERSION}-x86_64_v4.pkg.tar.zst"
        metadata = f"pkgname = {name}\npkgver = {version}\narch = {arch}\n"
        if duplicate:
            metadata += "arch = x86_64_v4\n"
        # Uncompressed fixture: both bsdtar and tar autodetect the stream.
        with tarfile.open(path, "w") as archive:
            for filename, data in {".PKGINFO": metadata, ".BUILDINFO": "format = 2\n"}.items():
                data = data.encode()
                info = tarfile.TarInfo(filename)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return path

    def test_package_metadata_and_checksum(self):
        package = self.package()
        result = self.run_script("scripts/verify-package.sh", self.work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / "SHA256SUMS").read_text(),
                         f"{hashlib.sha256(package.read_bytes()).hexdigest()}  {package.name}\n")
        self.assertTrue((self.work / "package.BUILDINFO").is_file())

    def test_wrong_or_ambiguous_package_is_rejected(self):
        for metadata in ({"name": "other"}, {"version": "1.2.3.4-1"},
                         {"arch": "x86_64"}, {"duplicate": True}):
            with self.subTest(metadata=metadata):
                self.package(**metadata)
                result = self.run_script("scripts/verify-package.sh", self.work)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.work / "SHA256SUMS").exists())

    def test_shared_retry_preserves_failure_status(self):
        result = subprocess.run(["bash", "-c", 'source "$1"; retry 3 0 bash -c "exit 17"',
                                 "--", str(ROOT / "scripts/container-common.sh")],
                                capture_output=True, text=True, env=self.env, timeout=10)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(result.stderr.count("warning: attempt"), 3)

    def test_manual_fetch_checksum_matches_recipe(self):
        recipe = (ROOT / "PKGBUILD").read_text()
        expected = re.search(r"sha256sums\[0\]='([a-f0-9]+)'", recipe)[1]
        self.assertEqual(expected, hashlib.sha256((ROOT / "fetch-chromium-release").read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
