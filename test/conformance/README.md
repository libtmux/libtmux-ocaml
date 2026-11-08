# Java/OCaml scalar conformance

Run both real query evaluators over the same captured pane values, then read
each implementation's encoded queries in the other implementation. The
[66 cases](cases.json) cover the [shared scalar subset](../../docs/query-interchange.md).
They do not qualify transports, relationships or Java regex.

## Prepare the Java peer

Use Python 3.11 or newer, Git, Temurin JDK 25 and the project's prepared OCaml
switch. Set `JAVA_HOME` to that JDK, or pass `--java-home` to both scripts.

Preparation fetches the exact [Java revision][java-source], uses its checked
Gradle wrapper and builds only the core and Jackson runtime classpath. Run it
outside validation loops; the first run can download Gradle and dependencies:

```console
$ python3 test/conformance/prepare.py
```

The prepared directory is `scratch/java-conformance-prepared`. Its manifest
records the source revision, JDK identities, preparation inputs and every jar
and peer-class digest. Gradle compilation must select the same JDK; automatic
JDK discovery and downloads are disabled. Gradle resolves the classpath; the
runner does not search Gradle's cache layout or assume artifact filenames.
Temporary source and build
directories are removed after preparation. Logs remain beside the manifest.

Repeated preparation verifies the cache. Changed inputs, artifacts or JDKs
require a new directory; existing output is never silently replaced:

```console
$ python3 test/conformance/prepare.py \
    --output scratch/java-conformance-next
```

For offline preparation, supply a local Git repository containing the pinned
commit and a populated Gradle cache:

```console
$ python3 test/conformance/prepare.py \
    --source-repo ../libtmux-java \
    --offline
```

`--source-repo` alone makes Git acquisition local. Only `--offline` also disables
Gradle dependency downloads. Failed builds retain their logs in the reported
staging directory and do not publish a prepared cache.

## Qualify both directions

With the default prepared cache:

```console
$ opam exec -- python3 test/conformance/run.py
```

The runner verifies the manifest, builds the current OCaml peer with an explicit
project root and records its source archive, executable digest and tool versions.
It checks every fixture
case exactly once in each evaluator and in both codec directions. Duplicate,
missing or unexpected case names fail the run.

Each run creates a new directory under `scratch/conformance-results`. It keeps
the original fixture, both encoded documents, all stdout/stderr, command exit
statuses and `result.json`, including failures. A successful result reports
`"status": "PASS"` and `"cases": 66`. To choose another prepared cache and an
explicit new result directory:

```console
$ opam exec -- python3 test/conformance/run.py \
    --setup scratch/java-conformance-next \
    --output scratch/conformance-results/next
```

This is a separate outer qualification step. Ordinary OCaml CI checks the
runner's evidence validation without a JVM; it does not run cross-language
conformance. The Java artifacts are development fixtures, not OCaml package
dependencies.

[java-source]: https://github.com/libtmux/libtmux-java/tree/e8a39689d8d60968ac978a1dd2a89c6112333896
