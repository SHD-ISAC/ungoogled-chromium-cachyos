"""Exercise proxy routing and automatic prefetch without starting real containers."""
import fcntl
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

    def test_no_automatic_prefetch_fails_early_without_a_completed_cache(self):
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
            self.assertIn("rm -f ungoogled-chromium-prefetch-", self.log.read_text())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
