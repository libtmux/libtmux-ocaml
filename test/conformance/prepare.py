"""Prepare a verified Java peer outside the ordinary OCaml validation loops."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
REVISION = "e8a39689d8d60968ac978a1dd2a89c6112333896"
REPOSITORY = "https://github.com/libtmux/libtmux-java.git"
DEFAULT_SETUP = ROOT / "scratch/java-conformance-prepared"
SCHEMA = "libtmux.conformance-java/1"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def run_logged(command, directory, label, steps, *, cwd=ROOT, env=None, timeout=300):
    """Retain both streams and the exit status, including failed commands."""
    started = time.monotonic()
    step = {"name": label, "command": list(map(str, command))}
    steps.append(step)
    with (directory / f"{label}.stdout").open("wb") as stdout:
        with (directory / f"{label}.stderr").open("wb") as stderr:
            try:
                result = subprocess.run(command, cwd=cwd, env=env, stdout=stdout,
                                        stderr=stderr, timeout=timeout, check=False)
                step["exit_code"] = result.returncode
                if result.returncode:
                    raise RuntimeError(f"{label} exited {result.returncode}; see {directory}")
            except BaseException as error:
                step["error"] = str(error)
                raise
            finally:
                step["seconds"] = round(time.monotonic() - started, 4)
    return (directory / f"{label}.stdout").read_text()


def toolchain(java_home=None):
    env = os.environ.copy()
    if java_home is not None:
        env["JAVA_HOME"] = str(java_home.resolve())
    if env.get("JAVA_HOME"):
        env["PATH"] = str(Path(env["JAVA_HOME"]) / "bin") + os.pathsep + env["PATH"]
    commands, identity = {}, {}
    for name in ("java", "javac"):
        executable = shutil.which(name, path=env["PATH"])
        if executable is None:
            raise RuntimeError(f"{name} is missing; select a Temurin JDK 25 with --java-home")
        path = Path(executable).resolve()
        version = subprocess.check_output([str(path), "-version"], stderr=subprocess.STDOUT,
                                          env=env, text=True).strip()
        commands[name] = str(path)
        identity[name] = {"version": version, "sha256": digest(path)}
    if not identity["javac"]["version"].startswith("javac 25"):
        raise RuntimeError("this qualification uses JDK 25; select it with --java-home")
    if Path(commands["java"]).parent != Path(commands["javac"]).parent:
        raise RuntimeError("java and javac must come from the same JDK")
    env["JAVA_HOME"] = str(Path(commands["java"]).parent.parent)
    return commands, identity, env


def build_inputs():
    return {f"test/conformance/{name}": digest(HERE / name)
            for name in ("prepare.py", "artifacts.gradle", "FilterPeer.java")}


def artifact_hashes(directory):
    return {str(path.relative_to(directory)): digest(path)
            for folder in ("jars", "classes")
            for path in sorted((directory / folder).rglob("*")) if path.is_file()}


def verify_setup(directory, identity):
    manifest = json.loads((directory / "manifest.json").read_text())
    for key, expected in (("schema", SCHEMA), ("revision", REVISION),
                          ("inputs", build_inputs()), ("toolchain", identity)):
        if manifest.get(key) != expected:
            raise RuntimeError(f"prepared Java {key} differs; prepare a new --output directory")
    actual = artifact_hashes(directory)
    if not actual or manifest.get("artifacts") != actual:
        raise RuntimeError("prepared Java artifact digests differ; prepare a new --output directory")
    jars = sorted(name for name in actual if name.startswith("jars/"))
    if not jars or any(not name.endswith(".jar") for name in jars):
        raise RuntimeError("prepared Java classpath must contain jars")
    if "classes/io/github/libtmux/FilterPeer.class" not in actual:
        raise RuntimeError("prepared Java peer is missing")
    return manifest, [directory / name for name in jars]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_SETUP)
    parser.add_argument("--source-repo", type=Path,
                        help="acquire the pinned Git objects locally; Gradle may still use the network")
    parser.add_argument("--java-home", type=Path, help="Temurin JDK 25 installation")
    parser.add_argument("--offline", action="store_true", help="also require cached Gradle dependencies")
    args = parser.parse_args()
    output = args.output.resolve()
    commands, identity, env = toolchain(args.java_home)
    if output.exists():
        verify_setup(output, identity)
        print(f"PASS prepared Java cache verified: {output}")
        return
    if args.offline and args.source_repo is None:
        parser.error("--offline also needs --source-repo for Git acquisition")
    output.parent.mkdir(parents=True, exist_ok=True)
    staged = Path(tempfile.mkdtemp(prefix=".libtmux-java-", dir=output.parent))
    record = {"status": "FAIL", "revision": REVISION, "steps": []}
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="libtmux-java-build-", dir=output.parent) as work:
            source = Path(work)
            steps = record["steps"]
            run_logged(["git", "init", "--quiet", str(source)], staged, "git-init", steps)
            origin = str(args.source_repo.resolve()) if args.source_repo else REPOSITORY
            run_logged(["git", "fetch", "--depth=1", origin, REVISION], staged,
                       "git-fetch", steps, cwd=source)
            run_logged(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], staged,
                       "git-checkout", steps, cwd=source)
            actual = run_logged(["git", "rev-parse", "HEAD"], staged, "git-revision", steps,
                                cwd=source).strip()
            if actual != REVISION:
                raise RuntimeError("Java source revision differs from the pin")
            wrapper = source / "gradle/wrapper/gradle-wrapper.properties"
            shutil.copyfile(wrapper, staged / "gradle-wrapper.properties")
            jdk = Path(commands["javac"]).parent.parent
            gradle = [str(source / "gradlew"), "--no-daemon", "--max-workers=2",
                      "--no-configuration-cache", "--console=plain", "--init-script",
                      str(HERE / "artifacts.gradle"),
                      "-Dorg.gradle.java.installations.auto-detect=false",
                      "-Dorg.gradle.java.installations.auto-download=false",
                      "-Dorg.gradle.java.installations.fromEnv=",
                      f"-Dorg.gradle.java.installations.paths={jdk}",
                      f"-PocamlConformanceDir={staged / 'jars'}"]
            if args.offline:
                gradle.append("--offline")
            gradle.append(":libtmux-jackson:ocamlConformanceArtifacts")
            run_logged(gradle, staged, "gradle", steps, cwd=source, env=env)
            jars = sorted((staged / "jars").glob("*.jar"))
            if not jars:
                raise RuntimeError("Gradle produced no runtime artifacts")
            run_logged([commands["javac"], "--release", "25", "-cp",
                        os.pathsep.join(map(str, jars)), "-d", str(staged / "classes"),
                        str(HERE / "FilterPeer.java")], staged, "javac", steps, env=env)
            manifest = {"schema": SCHEMA, "repository": REPOSITORY, "revision": REVISION,
                        "toolchain": identity, "inputs": build_inputs(),
                        "artifacts": artifact_hashes(staged),
                        "wrapper_sha256": digest(wrapper)}
            write_json(staged / "manifest.json", manifest)
            verify_setup(staged, identity)
        record["status"] = "PASS"
    except BaseException as error:
        record["error"] = str(error)
        raise
    finally:
        record["seconds"] = round(time.monotonic() - started, 4)
        write_json(staged / "prepare.json", record)
        if record["status"] != "PASS":
            print(f"Preparation failed; diagnostics retained in {staged}")
    staged.rename(output)
    print(f"PASS prepared Java {REVISION}: {output} ({record['seconds']:.3f}s)")


if __name__ == "__main__":
    main()
