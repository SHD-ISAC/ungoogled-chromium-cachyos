"""Exercise proxy routing and automatic prefetch without starting real containers."""
import fcntl
import os
from pathlib import Path
import subprocess
import time
import unittest

from test_helpers import HelperFixtures, MARKER, ROOT, VERSION


class Orchestration(HelperFixtures):
    def host(self, commands):
        return subprocess.run(["bash", "-eu", "-c", 'source "$1"; ' + commands,
                               "--", str(ROOT / "scripts/host-common.sh")],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def docker(self, run_body="exit 37"):
        self.mock("docker", '''echo "$*" >> "$TEST_LOG"
case "$1" in
    info|pull|rm) exit 0 ;;
    context) echo default ;;
    image) echo sha256:fixture ;;
    run) ''' + run_body + ''' ;;
    *) exit 99 ;;
esac''')

    def test_saved_config_is_used_and_environment_overrides_it(self):
        config = self.work / "config/ungoogled-chromium-cachyos/build.env"
        config.parent.mkdir(parents=True)
        config.write_text("CHROMIUM_BUILD_JOBS=6\nCACHYOS_PROXY_URL=http://127.0.0.1:7890\n")
        result = self.host('load_build_config; printf "%s" "$CHROMIUM_BUILD_JOBS"')
        self.assertEqual(result.stdout, "6", result.stderr)
        self.env["CHROMIUM_BUILD_JOBS"] = "8"
        self.env["CACHYOS_PROXY_URL"] = ""
        result = self.host('load_build_config; printf "%s|%s" "$CHROMIUM_BUILD_JOBS" "$CACHYOS_PROXY_URL"')
        self.assertEqual(result.stdout, "8|", result.stderr)

    def test_loopback_proxy_uses_host_network_without_credentials_in_argv(self):
        self.docker()
        self.env["CACHYOS_PROXY_URL"] = "http://fixture:fixture-password@127.0.0.1:7890"
        result = self.host('container_network; docker run "${container_network_args[@]}" '
                           '"${container_proxy_args[@]}" fixture')
        self.assertEqual(result.returncode, 37, result.stderr)
        logged = self.log.read_text()
        self.assertIn("--network host", logged)
        self.assertIn("-e http_proxy -e HTTP_PROXY", logged)
        self.assertNotIn("fixture-password", logged)

    def test_proxy_is_exported_for_all_child_download_tools(self):
        self.docker()
        self.env["CACHYOS_PROXY_URL"] = "http://192.0.2.1:7890"
        result = self.host('container_network; bash -c \'printf "%s|%s|%s" '
                           '"$http_proxy" "$HTTPS_PROXY" "$ALL_PROXY"\'')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "|".join([self.env["CACHYOS_PROXY_URL"]] * 3))

    def test_lowercase_proxy_wins_and_no_proxy_is_preserved(self):
        self.docker()
        self.env.update(http_proxy="http://192.0.2.1:7890",
                        HTTP_PROXY="http://192.0.2.2:7890", NO_PROXY="localhost,.internal")
        result = self.host('container_network; printf "%s|%s|%s" '
                           '"$http_proxy" "$HTTP_PROXY" "$no_proxy"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "http://192.0.2.1:7890|http://192.0.2.1:7890|localhost,.internal")

    def test_incompatible_proxy_routes_fail_before_starting_a_container(self):
        self.docker()
        for proxy, network in (("socks5h://127.0.0.1:7891", "auto"),
                               ("http://127.0.0.1:7890", "bridge")):
            self.env.update(CACHYOS_PROXY_URL=proxy, CACHYOS_DOCKER_NETWORK=network)
            result = self.host("container_network")
            self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_remote_daemon_cannot_use_the_laptop_loopback_proxy(self):
        self.docker()
        self.env.update(CACHYOS_PROXY_URL="http://127.0.0.1:7890", DOCKER_HOST="ssh://fixture.invalid")
        result = self.host("container_network")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reachable from the Docker host", result.stderr)

    def test_missing_source_is_prefetched_automatically_and_reused_next_time(self):
        self.use_manual_recipe()
        self.docker('''if [[ ${@: -1} == /recipe/scripts/container-prefetch.sh ]]; then
    for arg in "$@"; do
        case "$arg" in
            *:/work) stage=${arg%:/work} ;;
            CHROMIUM_VERSION=*) version=${arg#CHROMIUM_VERSION=} ;;
        esac
    done
    mkdir -p "$stage/chromium-$version"
    touch "$stage/chromium-$version/.ungoogled-chromium-cache-complete"
    exit 0
fi
echo 'compiler fixture failure'
exit 37''')
        for invocation in (1, 2):
            self.env["CACHYOS_OUTPUT_DIR"] = str(self.work / f"output-{invocation}")
            result = self.run_script("cachyos-build.sh")
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
            self.assertTrue((self.work / f"cache/chromium-source/chromium-{VERSION}" / MARKER).exists())
        commands = self.log.read_text().splitlines()
        self.assertEqual(sum("container-prefetch.sh" in line for line in commands), 1)
        self.assertEqual(sum(line.startswith("pull ") for line in commands), 2)
        self.assertEqual(sum("container-build.sh" in line for line in commands), 2)
        self.assertEqual(sum(f"{self.work}/cache/pacman:/var/cache/pacman/pkg" in line for line in commands), 3)

    def test_no_automatic_prefetch_fails_early_without_a_completed_cache(self):
        self.use_manual_recipe()
        self.docker()
        self.env.update(CACHYOS_AUTO_PREFETCH="0", CACHYOS_OUTPUT_DIR=str(self.work / "output"))
        result = self.run_script("cachyos-build.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requested source cache is missing", result.stderr)
        self.assertNotIn("run --", self.log.read_text())

    def test_local_and_actions_builds_share_a_cache_lock(self):
        cache = self.work / "cache"
        cache.mkdir()
        self.docker()
        with (cache / ".build.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("cachyos-build.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another build", result.stderr)
        self.assertFalse(self.log.exists())

    def test_image_pull_exhaustion_does_not_silently_use_an_old_image(self):
        self.mock("docker", 'echo "$*" >> "$TEST_LOG"; [[ $1 != pull ]] || exit 23')
        result = self.host("resolve_build_image fixture")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.log.read_text().count("pull fixture"), 3)
        self.assertNotIn("image inspect", self.log.read_text())

    def test_ensure_docker_starts_only_a_stopped_local_service(self):
        self.env["CACHYOS_START_DOCKER"] = "auto"
        self.mock("docker", '''case "$1" in
    info) test -f "$TEST_LOG.started" ;;
    context) echo default ;;
esac''')
        self.mock("systemctl", "exit 3")
        self.mock("sudo", 'echo "$*" >> "$TEST_LOG"; touch "$TEST_LOG.started"')
        for mode, expected in (("false", "systemctl start docker"),
                               ("true", "-n systemctl start docker")):
            with self.subTest(ci=mode):
                self.env["CI"] = mode
                self.log.unlink(missing_ok=True)
                Path(str(self.log) + ".started").unlink(missing_ok=True)
                result = self.host("ensure_docker")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.log.read_text().strip(), expected)

    def test_unreachable_remote_docker_does_not_start_a_local_service(self):
        self.env.update(CACHYOS_START_DOCKER="auto", DOCKER_HOST="ssh://fixture.invalid")
        self.mock("docker", "exit 23")
        self.mock("sudo", 'echo unexpected >> "$TEST_LOG"; exit 99')
        result = self.host("ensure_docker")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_runner_runs_once_and_uses_a_separate_proxy_setting(self):
        self.docker()
        runner = self.work / "runner"
        runner.mkdir()
        script = runner / "run.sh"
        script.write_text('#!/usr/bin/env bash\nprintf "%s|%s" "$*" "${http_proxy:-}"\n')
        script.chmod(0o755)
        self.env.update(CACHYOS_RUNNER_DIR=str(runner),
                        CACHYOS_PROXY_URL="http://192.0.2.1:7890",
                        CACHYOS_RUNNER_PROXY_URL="http://192.0.2.2:7890")
        result = self.run_script("scripts/run-runner.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "--once|http://192.0.2.2:7890")

    def test_cancellation_during_automatic_prefetch_removes_its_container(self):
        self.use_manual_recipe()
        self.env.update(CACHYOS_OUTPUT_DIR=str(self.work / "output"),
                        PID_FILE=str(self.work / "prefetch.pid"))
        # Killing the Docker client models removing the named container.
        self.mock("docker", '''echo "$*" >> "$TEST_LOG"
case "$1" in
    info|pull) exit 0 ;;
    context) echo default ;;
    image) echo sha256:fixture ;;
    run) echo $$ > "$PID_FILE"; exec /bin/sleep 30 ;;
    rm) if [[ $* == *prefetch* ]]; then kill "$(cat "$PID_FILE")"; fi ;;
    *) exit 99 ;;
esac''')
        process = subprocess.Popen(["bash", str(self.root / "cachyos-build.sh")],
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
            self.assertIn("rm -f ungoogled-chromium-prefetch-", self.log.read_text())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_archive_mode_skips_git_prefetch_and_keeps_both_download_caches(self):
        self.docker()
        for invocation in (1, 2):
            self.env.update(CACHYOS_AUTO_PREFETCH="0", CACHYOS_OUTPUT_DIR=str(self.work / f"output-{invocation}"))
            result = self.run_script("cachyos-build.sh")
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        commands = self.log.read_text()
        self.assertNotIn("container-prefetch.sh", commands)
        self.assertEqual(commands.count(f"{self.work}/cache/pacman:/var/cache/pacman/pkg"), 2)
        self.assertEqual(commands.count(f"{self.work}/cache/source-downloads:/source-downloads"), 2)

    def test_download_cache_lock_prevents_concurrent_pacman_containers(self):
        self.docker()
        cache = self.work / "cache"
        cache.mkdir()
        self.env["CACHYOS_OUTPUT_DIR"] = str(self.work / "output")
        with (cache / ".packages.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("cachyos-build.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("package download cache", result.stderr)
        self.assertNotIn("container-build.sh", self.log.read_text())

    def test_check_does_not_start_docker_download_or_create_directories(self):
        self.docker()
        self.env["CACHYOS_PROXY_URL"] = "http://fixture:secret@127.0.0.1:7890"
        result = self.run_script("cachyos-build.sh", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.work / "cache").exists())
        self.assertNotIn("secret", result.stdout + result.stderr + self.log.read_text())
        self.assertIn(str(Path(os.environ["HOME"]) / "Downloads/ungoogled-chromium-builds"), result.stdout)
        self.assertIn("no Git prefetch", result.stdout)
        self.assertTrue(all(line in ("context show", "info") for line in self.log.read_text().splitlines()))

    def test_incompatible_cpu_fails_before_docker_or_cache_creation(self):
        self.docker()
        self.mock("lscpu", 'echo "Flags: avx avx2"')
        result = self.run_script("cachyos-build.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing x86-64-v4 CPU flag", result.stderr)
        self.assertFalse((self.work / "cache").exists())
        self.assertFalse(self.log.exists())

    def test_unknown_build_options_fail_without_side_effects(self):
        self.docker()
        result = self.run_script("cachyos-build.sh", "--updat")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unknown option", result.stderr)
        self.assertFalse((self.work / "cache").exists())
        self.assertFalse(self.log.exists())

    def git(self, path, *args):
        return subprocess.run(["git", "-C", str(path), "-c", "user.name=Fixture",
                               "-c", "user.email=fixture@example.invalid", *args],
                              check=True, text=True, capture_output=True).stdout.strip()

    def update_fixture(self):
        self.use_manual_recipe()
        self.git(self.root, "init", "-q", "-b", "cachyos-znver4")
        self.git(self.root, "add", ".")
        self.git(self.root, "commit", "-qm", "initial")
        remote = self.work / "remote"
        subprocess.run(["git", "clone", "-q", str(self.root), str(remote)], check=True)
        self.git(self.root, "remote", "add", "origin", str(remote))
        self.env["CI"] = "false"
        return remote

    def test_update_fast_forwards_clean_checkout_and_runs_the_updated_script(self):
        remote = self.update_fixture()
        (remote / "cachyos-build.sh").write_text('#!/usr/bin/env bash\nprintf "updated:%s" "$*"\n')
        self.git(remote, "add", ".")
        self.git(remote, "commit", "-qm", "updated helper")
        result = self.run_script("cachyos-build.sh", "--update", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated:--check", result.stdout)
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD"), self.git(remote, "rev-parse", "HEAD"))

    def test_update_preserves_uncommitted_changes_and_does_not_fetch(self):
        self.update_fixture()
        local = self.root / "local-settings"
        local.write_text("keep this")
        result = self.run_script("cachyos-build.sh", "--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Commit or stash", result.stderr)
        self.assertFalse((self.root / ".git/FETCH_HEAD").exists())
        self.assertEqual(local.read_text(), "keep this")

    def test_update_rejects_diverged_history_without_resetting_local_commits(self):
        remote = self.update_fixture()
        (self.root / "local").touch()
        self.git(self.root, "add", ".")
        self.git(self.root, "commit", "-qm", "local work")
        local_head = self.git(self.root, "rev-parse", "HEAD")
        (remote / "upstream").touch()
        self.git(remote, "add", ".")
        self.git(remote, "commit", "-qm", "remote work")
        result = self.run_script("cachyos-build.sh", "--update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD"), local_head)
        self.assertTrue((self.root / "local").exists())

    def test_update_uses_proxy_without_putting_credentials_in_git_arguments(self):
        self.docker()
        self.env.update(CI="false", CACHYOS_PROXY_URL="http://fixture:secret@127.0.0.1:7890")
        self.mock("git", '''case "$*" in
    *"branch --show-current") echo cachyos-znver4 ;;
    *"status --porcelain") exit 0 ;;
    *"fetch origin"*)
        [[ $http_proxy == "$CACHYOS_PROXY_URL" && $https_proxy == "$CACHYOS_PROXY_URL" ]]
        echo "$*" >> "$TEST_LOG"; exit 29 ;;
    *) exit 99 ;;
esac''')
        result = self.run_script("cachyos-build.sh", "--update")
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertNotIn("secret", self.log.read_text() + result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
