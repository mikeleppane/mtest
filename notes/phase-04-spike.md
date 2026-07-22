# Phase 04 micro-spike — tooling + linkage + schema

Untracked working file (build/, notes/phase-04-spike.md are gitignore-covered for
the tracked set — this note is NOT git-added). No repo manifest was touched; all
ad-hoc tools ran via `pixi exec` / throwaway scratch envs. No `mojo run`; binary was
built then executed. No remote/push/publish. Toolchain: mojo ==1.0.0b2.

Scratch root:
`/tmp/claude-1000/-home-mikko-dev-mtest/b7005a9f-dfee-413d-9db3-1c5a8bc8a288/scratchpad`

---

## Probe 1 — LINKAGE VERDICT

**VERDICT: NOT loader-clean.** `build/mtest` needs the Mojo runtime shared libs at
load time. The eventual conda recipe MUST declare a run-dependency on the package
that ships them: **`mojo-compiler ==1.0.0b2`** (from `https://conda.modular.com/max/`;
the `mojo` metapackage depends on it). The build-host RUNPATH is an ABSOLUTE path
into `.pixi/` and must NOT be relied on post-install.

### Build (exactly as the gate does)
```
rm -f build/mtest && pixi run build-bin
# build (precompile src/mtest -> build/mtest.mojopkg)
# build-native (python scripts/build_native.py -> build/native/mtest_exec_native.o[+ _test.o])
# build-bin: mojo build -I build src/main.mojo -o build/mtest -Xlinker build/native/mtest_exec_native.o
# -> build/mtest (792k)
```

### `ldd build/mtest`
Full transitive soname list (all non-system libs resolve into the build-host pixi env):
```
libKGENCompilerRTShared.so => .pixi/envs/default/lib/...   (direct NEEDED)
libstdc++.so.6            => .pixi/envs/default/lib/...
libMSupportGlobals.so     => .pixi/envs/default/lib/...
libAsyncRTRuntimeGlobals.so => .pixi/envs/default/lib/...
libNVPTX.so              => .pixi/envs/default/lib/...
libAsyncRTMojoBindings.so => .pixi/envs/default/lib/...
libgcc_s.so.1            => .pixi/envs/default/lib/...
libc.so.6, libm.so.6, libdl.so.2, ld-linux-x86-64.so.2   (system)
```

### `readelf -d build/mtest`
- NEEDED (direct): `libKGENCompilerRTShared.so`, `libc.so.6` only.
- **RUNPATH**: `/home/mikko/dev/mtest/.pixi/envs/default/lib` (absolute, build-host).
- FLAGS: BIND_NOW; FLAGS_1: NOW PIE.

The other pixi-env sonames in `ldd` are the transitive closure pulled in by
`libKGENCompilerRTShared.so`; `conda-meta` ownership check attributes every one of
`libKGENCompilerRTShared/libMSupportGlobals/libAsyncRTRuntimeGlobals/libNVPTX/libAsyncRTMojoBindings`
to **`mojo-compiler-1.0.0b2-release`**.

### LOADER-CLEAN probe (our own artifact; NOT forbidden child-env scrubbing)
Ran the binary from a scratch cwd with the pixi env absent from PATH and empty
LD_LIBRARY_PATH:
```
cd <scratch>/loader-probe
env -i PATH=/usr/bin:/bin HOME=$HOME LD_LIBRARY_PATH= /home/mikko/dev/mtest/build/mtest --version
# -> mtest 0.1.0-dev            EXIT=0
env -i PATH=/usr/bin:/bin HOME=$HOME LD_LIBRARY_PATH= /home/mikko/dev/mtest/build/mtest --help
# -> usage banner              EXIT=0
```
Both ran — but ONLY because the baked absolute RUNPATH still resolves on the build
host. To expose the true dependency, RUNPATH was neutralized on a scratch COPY:
```
cp build/mtest <scratch>/mtest-norunpath
pixi exec patchelf --remove-rpath <scratch>/mtest-norunpath
ldd <scratch>/mtest-norunpath        # libKGENCompilerRTShared.so => not found
cd <scratch> && env -i PATH=/usr/bin:/bin HOME=$HOME LD_LIBRARY_PATH= <scratch>/mtest-norunpath --version
# -> error while loading shared libraries: libKGENCompilerRTShared.so: cannot open ...   EXIT=127
```
**Ground truth run-dependency set** the recipe must satisfy: `libKGENCompilerRTShared.so`
(+ its transitive `libstdc++/libMSupportGlobals/libAsyncRTRuntimeGlobals/libNVPTX/libAsyncRTMojoBindings/libgcc_s`),
all provided by `mojo-compiler ==1.0.0b2`. The native adapter is **statically linked**
(NEEDED shows no extra native soname) — confirms the pixi.toml claim that the C
object adds no runtime library dependency.

---

## Probe 2 — RATTLER LOOP

**VERDICT: IN-ENV BUILD branch.** mojo ==1.0.0b2 installs into rattler-build's
ISOLATED build environment and runs there. The recipe can build from source inside
rattler's sandbox; the prebuilt-binary branch is NOT forced. No human escalation.

rattler-build reached via `pixi exec` (NOT added to the repo manifest): `rattler-build 0.69.1`.

### mojo-in-isolated-build-env proof
Recipe `<scratch>/rattler-probe/recipe/recipe.yaml`:
```yaml
package: { name: mtest-mojo-probe, version: "0.1.0" }
build:
  number: 0
  script:
    - mojo --version
    - echo "MOJO-IN-BUILD-ENV-OK"
requirements:
  build:
    - mojo ==1.0.0b2
```
```
cd <scratch>/rattler-probe
pixi exec rattler-build build --recipe recipe/recipe.yaml \
  -c https://conda.modular.com/max/ -c conda-forge --output-dir output
```
Build env solved (mojo 1.0.0b2 + mojo-compiler 1.0.0b2 + mojo-python 1.0.0b2 from
`max` channel, deps from conda-forge). Build script output:
```
+ mojo --version
Mojo 1.0.0b2 (2cf4d08a)
+ echo MOJO-IN-BUILD-ENV-OK
MOJO-IN-BUILD-ENV-OK
```
Artifact produced: `output/linux-64/mtest-mojo-probe-0.1.0-*.conda`. → mojo IS
installable and runnable in rattler's sandbox. (Full mtest-from-source in-env is
therefore viable; not built here to keep the spike minimal.)

### Local-channel build -> scratch-env install -> EXECUTE loop (commands)
Stub package used ONLY to teach the command sequence — no verdict rests on stub
behavior. Zero network beyond the solve (stub package is local; conda-forge deps
come from cache/solve, same as pixi).
```
# 1. build local channel (rattler output dir IS a conda channel: has repodata.json)
cat <scratch>/stub-probe/recipe/recipe.yaml
#   package: {name: mtest-stub, version: "0.1.0"}
#   build: {number: 0, noarch: generic, script: [ mkdir -p $PREFIX/bin,
#           printf '#!/bin/sh\necho "..."\n' > $PREFIX/bin/mtest-stub, chmod +x ... ]}
cd <scratch>/stub-probe
pixi exec rattler-build build --recipe recipe/recipe.yaml -c conda-forge --output-dir channel
#   -> channel/noarch/mtest-stub-0.1.0-*.conda  + channel/noarch/repodata.json

# 2. install from the local channel into a scratch env AND 3. execute
pixi exec --channel file://<scratch>/stub-probe/channel --channel conda-forge \
  --spec mtest-stub -- mtest-stub
#   -> mtest-stub 0.1.0 (local-channel loop OK)   EXIT=0
```
For the REAL package the same loop applies; the installed env must also pull
`mojo-compiler ==1.0.0b2` at run time (Probe 1 verdict) whether the recipe builds
in-env or packages the gate binary.

---

## Probe 3 — SCHEMA PROOF

Vendored XSDs (in `<scratch>/xsd/`):

| file | source URL | license (from file header) |
|---|---|---|
| `junit-10.xsd` (PRIMARY dialect, Jenkins xUnit) | https://raw.githubusercontent.com/jenkinsci/xunit-plugin/master/src/main/resources/org/jenkinsci/plugins/xunit/types/model/xsd/junit-10.xsd | **MIT License (MIT)**, Copyright (c) 2014 Gregory Boissinot — confirmed in header |
| `surefire-test-report.xsd` (PROVENANCE only) | https://maven.apache.org/surefire/maven-surefire-plugin/xsd/surefire-test-report.xsd | **Apache License 2.0** (ASF), schema `version="3.0.2"` — confirmed in header |

### What the PRIMARY XSD actually defines (read, not assumed)
- `<testsuites>` root: attrs `name, time, tests, failures, errors` — **all OPTIONAL**;
  **NO `skipped` attribute**; body = `testsuite*`.
- `<testsuite>`: **REQUIRED** `name, tests, failures, errors`; OPTIONAL `group, time
  (SUREFIRE_TIME), skipped, timestamp, hostname, id, package, file, log, url, version`;
  body = choice* of `testsuite | properties | testcase | system-out | system-err`
  (so **suite-level `system-out` IS accepted**).
- `<testcase>`: **REQUIRED** `name`; OPTIONAL `time, classname, group`; body = choice*
  of `skipped|error|failure|rerunFailure|rerunError|flakyFailure|flakyError|system-out|system-err`
  (choice → order-lenient in junit-10).
- **flakyFailure content model** (`rerunType`, shared by flakyFailure/flakyError/
  rerunFailure/rerunError): `mixed="true"` (text allowed); ordered children, ALL
  minOccurs=0: `stackTrace`, `system-out`, `system-err`; attributes: `message`
  (optional), **`type` (use="required")**. Negative probe confirmed: dropping `type`
  fails validation ("attribute 'type' is required but missing"). The renderer MUST
  emit `type` on every flaky/rerun element.
- Surefire (provenance): single `<testsuite>` root, **NO `<testsuites>`**; strict
  SEQUENCE gives the chronology (`failure*, rerunFailure*, flakyFailure*, skipped?,
  error?, rerunError*, flakyError*, ...`); requires `skipped` on testsuite and
  `time` (xs:float) on testcase. Cross-check: our multi-suite doc is REJECTED by
  surefire ("No matching global declaration available for the validation root") —
  proof it is tag-name provenance only, not our validation dialect.

### Commands
```
pixi exec --spec libxml2 -- xmllint --schema junit-10.xsd --noout mock.xml
pixi exec --spec libxml2 -- xmllint --schema junit-10.xsd --noout mock-fallback.xml
pixi exec --spec libxml2 -- xmllint --schema junit-10.xsd --noout mock-notype.xml
pixi exec --spec libxml2 -- xmllint --schema surefire-test-report.xsd --noout mock-fallback.xml
```
- `mock.xml` = full INTENDED emitter doc (testsuites root; per-file testsuite;
  node-id-sorted testcases w/ dotted classname; sentinels `[build] [attempts]
  [not-run] [output]`; flakyFailure retried-pass; `<failure>`+`<rerunFailure>`
  rerun-exhausted; `<error>`+`<rerunError>`; suite-level system-out; aggregate
  counts incl. `skipped` on BOTH testsuite AND testsuites; NO per-testcase `time`;
  NO suite `timestamp`).
- `mock-fallback.xml` = identical except the single `skipped` attr removed from the
  `<testsuites>` root.

### Outcome table — branch assigned per probed feature
| # | Feature | xmllint result | BRANCH |
|---|---|---|---|
| 1 | `<testsuites>` root | accepted (junit-10) | **(i)** full acceptance |
| 2 | per-file `<testsuite>` (name=path, req tests/failures/errors, time decimal) | accepted | **(i)** |
| 3 | `<testcase name classname>` node-id-sorted, dotted-stem classname | accepted | **(i)** |
| 4 | sentinels `[build] [attempts] [not-run] [output]` (literal names) | accepted | **(i)** |
| 5 | `flakyFailure` (retried-pass) w/ required `type` + stackTrace/system-out/system-err | accepted | **(i)** |
| 6 | rerun-exhausted: `<failure>` primary + `<rerunFailure>` (and `<error>`+`<rerunError>`) | accepted | **(i)** |
| 7 | suite-level `<system-out>` | accepted | **(i)** — NOT branch (v); `[output]` fallback NOT needed at schema level |
| 8 | aggregate counts on `<testsuite>` (tests/failures/errors + optional skipped) | accepted | **(i)** |
| 9 | aggregate **`skipped` on `<testsuites>` root** | **REJECTED** ("attribute 'skipped' is not allowed") | **(iii)** drop the attr; skipped arithmetic moves to the checker. NOT load-bearing beyond an attribute → **no escalation** |
| 10 | OMITTED per-testcase `time` | fallback validates | optional in XSD → **NOT branch (iv)**; no escalation |
| 11 | OMITTED suite `timestamp` | fallback validates | optional in XSD → **NOT branch (iv)**; no escalation |

Result excerpts:
```
# A) full intended mock
mock.xml:4: Schemas validity error : Element 'testsuites', attribute 'skipped':
            The attribute 'skipped' is not allowed.
mock.xml fails to validate
# B) fallback (skipped dropped from <testsuites> only)
mock-fallback.xml validates
# D) flakyFailure without type
mock-notype.xml:27: Element 'flakyFailure': The attribute 'type' is required but missing.
# C) surefire vs our multi-suite doc
mock-fallback.xml:4: Element 'testsuites': No matching global declaration available ...
```

### Designed validation gate
Ship the artifact with the `skipped` aggregate present on `<testsuite>` (valid) and
ABSENT from `<testsuites>` (branch iii). Gate = `xmllint --schema junit-10.xsd
--noout <artifact>` MUST pass, PLUS a structural checker that (a) recomputes the
`<testsuites>`-level skipped/tests/failures/errors totals from the child suites
(arithmetic the schema can't hold) and (b) asserts the flaky/rerun elements and
their required `type` attrs are present. No probed feature landed outside branches
(i)–(v); no STOP condition.

---

## ESCALATIONS TO HUMAN
**NONE.** No contract-omitted REQUIRED attribute (per-testcase `time` and suite
`timestamp` are both OPTIONAL in junit-10). No load-bearing base-document rejection
(the `<testsuites>` root is accepted by the primary dialect). No schema outcome fit
zero branches. The only rejection (`testsuites/@skipped`) is a plain attribute →
branch (iii), handled by the checker, not escalated. Rattler forces no prebuilt
tradeoff (in-env build works), so no reproducibility escalation either.
