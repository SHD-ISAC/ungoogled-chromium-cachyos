"""Check clean-build output, cleanup boundaries and failure handling."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import tarfile
import unittest

from test_helpers import HelperFixtures, PACKAGE_VERSION


@unittest.skipIf(os.geteuid() == 0, "clean builds require a non-root user")
class CleanBuild(HelperFixtures):
    def setUp(self):
        super().setUp()
        self.parent = self.work / "temporary builds"
        self.parent.mkdir()
        self.output = self.work / "result"
        self.runtime_log = self.work / "runtimes"
        self.addCleanup(self.remove_test_runtimes)
        self.original = self.work / "existing-podman"
        self.original.mkdir()
        (self.original / "keep").write_text("existing image")
        old_cache = self.work / "cache"
        old_cache.mkdir()
        (old_cache / "keep").write_text("existing downloads")
        self.package = self.work / f"ungoogled-chromium-{PACKAGE_VERSION}-x86_64_v4.pkg.tar.zst"
        self.write_package("x86_64_v4")
        self.env.update(CACHYOS_CLEAN_PARENT=str(self.parent), CACHYOS_OUTPUT_DIR=str(self.output),
                        CACHYOS_IMAGE_PULL="never", XDG_DATA_HOME=str(self.original),
                        CONTAINER_HOST="ssh://fixture.invalid", CONTAINERS_CONF_OVERRIDE=str(self.original / "conf"),
                        TEST_PARENT=str(self.parent), TEST_PACKAGE=str(self.package),
                        TEST_RUNTIME_LOG=str(self.runtime_log))
        self.mock("docker", 'echo "unexpected Docker command" >> "$TEST_LOG"; exit 99')
        self.mock("podman", r'''
echo "$*" >> "$TEST_LOG"
if [[ $1 == --version ]]; then echo 'podman version fixture'; exit 0; fi
[[ $1 == --remote=false && -z ${CONTAINER_HOST:-} && -z ${CONTAINERS_CONF_OVERRIDE:-} ]]
shift
while [[ $1 == --* ]]; do
    case $1 in
        --root) graph=$2; shift ;;
        --runroot) runroot=$2; shift ;;
        --volumepath) volumes=$2; shift ;;
        --tmpdir) shift ;;
        --events-backend=*|--cgroup-manager=*) ;;
        *) exit 98 ;;
    esac
    shift
done
for path in "$graph" "$volumes" "$XDG_DATA_HOME" "$TMPDIR"; do
    [[ $path == "$TEST_PARENT"/.uc-build.*/* ]]
done
[[ $XDG_RUNTIME_DIR == /tmp/ucp.* && $runroot == "$XDG_RUNTIME_DIR/run" && ${#runroot} -le 50 ]]
printf '%s\n' "$XDG_RUNTIME_DIR" >> "$TEST_RUNTIME_LOG"
case $1 in
    info) printf '%s|%s|%s|true\n' "${TEST_REPORTED_ROOT:-$graph}" "$runroot" "$volumes" ;;
    pull)
        if [[ -n ${CACHYOS_PROXY_URL:-} ]]; then
            [[ $http_proxy == "$CACHYOS_PROXY_URL" && $https_proxy == "$CACHYOS_PROXY_URL" ]]
        fi
        mkdir -p "$graph/images"
        touch "$graph/images/downloaded"
        ;;
    image)
        [[ -f $graph/images/downloaded ]]
        if [[ $* == *RepoDigests* ]]; then echo 'repo_digests=[]'; else echo sha256:fixture; fi
        ;;
    run)
        [[ $* == *--userns=keep-id:uid=1000,gid=1000* && -f $graph/images/downloaded ]]
        for arg in "$@"; do
            case $arg in
                *:/output) output=${arg%:/output} ;;
                *:/work) stage=${arg%:/work} ;;
                CHROMIUM_VERSION=*) version=${arg#CHROMIUM_VERSION=} ;;
            esac
        done
        if [[ ${@: -1} == /recipe/scripts/container-prefetch.sh ]]; then
            mkdir -p "$stage/chromium-$version"
            touch "$stage/chromium-$version/.ungoogled-chromium-cache-complete"
            exit 0
        fi
        echo 'fixture compiler output'
        mkdir -p "$output/logs"
        echo 'fixture diagnostic' > "$output/logs/compiler.log"
        cp -- "$TEST_PACKAGE" "$output/"
        exit "${TEST_BUILD_RC:-0}"
        ;;
    rm) ;;
    system)
        [[ $2 == reset && $3 == --force ]]
        [[ ${TEST_RESET_FAIL:-0} == 0 ]] || exit 36
        rm -rf -- "$graph" "$runroot" "$volumes"
        ;;
    *) exit 99 ;;
esac''')

    def write_package(self, arch):
        metadata = f"pkgname = ungoogled-chromium\npkgver = {PACKAGE_VERSION}\narch = {arch}\n"
        with tarfile.open(self.package, "w") as archive:
            for name, data in ((".PKGINFO", metadata), (".BUILDINFO", "format = 2\n")):
                payload = data.encode()
                entry = tarfile.TarInfo(name)
                entry.size = len(payload)
                archive.addfile(entry, io.BytesIO(payload))

    def runtime_paths(self):
        if not self.runtime_log.exists():
            return set()
        return {Path(p) for p in self.runtime_log.read_text().splitlines()}

    def remove_test_runtimes(self):
        for path in self.runtime_paths():
            if path.parent == Path("/tmp") and path.name.startswith("ucp.") and path.is_dir():
                shutil.rmtree(path)

    def assert_original_state_untouched(self):
        self.assertEqual((self.original / "keep").read_text(), "existing image")
        self.assertEqual((self.work / "cache/keep").read_text(), "existing downloads")
        self.assertNotIn("unexpected Docker command", self.log.read_text())

    def test_success_exports_only_a_verified_package_and_cleans_the_private_store(self):
        self.env["CACHYOS_PROXY_URL"] = "http://fixture:secret@127.0.0.1:7890"
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({p.name for p in self.output.iterdir()}, {self.package.name, "SHA256SUMS"})
        digest = hashlib.sha256((self.output / self.package.name).read_bytes()).hexdigest()
        self.assertEqual((self.output / "SHA256SUMS").read_text(), f"{digest}  {self.package.name}\n")
        self.assertEqual(list(self.parent.iterdir()), [])
        self.assertTrue(self.runtime_paths())
        self.assertTrue(all(not p.exists() for p in self.runtime_paths()))
        self.assert_original_state_untouched()
        commands = self.log.read_text()
        self.assertIn("pull docker.io/cachyos/docker-makepkg-znver4:latest", commands)
        self.assertIn("--network host", commands)
        self.assertNotIn("secret", commands + result.stdout + result.stderr)

    def test_build_failure_keeps_logs_but_does_not_export_a_package(self):
        self.env["TEST_BUILD_RC"] = "37"
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        self.assertIn("fixture compiler output", (self.output / "build.log").read_text())
        self.assertTrue((self.output / "logs/compiler.log").is_file())
        self.assertFalse((self.output / self.package.name).exists())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_a_wrong_architecture_is_not_exported(self):
        self.write_package("x86_64")
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Package mismatch", result.stderr)
        self.assertFalse((self.output / self.package.name).exists())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_cleanup_failure_is_reported_even_after_successful_compilation(self):
        self.env["TEST_RESET_FAIL"] = "1"
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cleanup failed", result.stderr)
        self.assertNotIn("Build complete:", result.stdout)
        self.assertTrue((self.output / self.package.name).is_file())
        self.assertTrue(any(self.parent.iterdir()))
        self.assert_original_state_untouched()

    def test_unexpected_storage_path_is_rejected_before_pull_or_reset(self):
        self.env["TEST_REPORTED_ROOT"] = str(self.original)
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to use or reset", result.stderr)
        self.assertNotIn(" pull ", self.log.read_text())
        self.assertNotIn(" system reset ", self.log.read_text())
        self.assert_original_state_untouched()

    def test_check_creates_neither_outputs_nor_a_container_store(self):
        result = self.run_script("cachyos-build.sh", "--check", "--clean")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text().strip(), "--version")
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_git_prefetch_uses_the_same_disposable_image_and_cache(self):
        self.use_manual_recipe()
        self.env["CACHYOS_AUTO_PREFETCH"] = "0"
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = self.log.read_text()
        self.assertEqual(commands.count(" pull "), 1)
        self.assertIn("container-prefetch.sh", commands)
        self.assertIn("container-build.sh", commands)
        self.assertEqual(list(self.parent.iterdir()), [])
        self.assert_original_state_untouched()

    def test_existing_output_is_left_alone(self):
        self.output.mkdir()
        valuable = self.output / "keep"
        valuable.write_text("previous build")
        result = self.run_script("cachyos-build.sh", "--clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output directory must be empty", result.stderr)
        self.assertEqual(valuable.read_text(), "previous build")
        self.assertFalse(self.log.exists())
        self.assertEqual(list(self.parent.iterdir()), [])
