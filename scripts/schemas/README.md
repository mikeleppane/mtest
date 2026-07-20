# Vendored JUnit XML schemas

Both files are vendored verbatim (including their license headers) from
upstream and are not modified. Attribution below is read directly from each
file's own header comment.

## `junit-10.xsd` — validation dialect

- Source: the Jenkins xUnit plugin's `junit-10.xsd`
  (`src/main/resources/org/jenkinsci/plugins/xunit/types/model/xsd/junit-10.xsd`
  in the `jenkinsci/xunit-plugin` repository).
- License: **MIT License (MIT)**, Copyright (c) 2014, Gregory Boissinot — read
  from the file's header comment.
- Role: this is the schema `scripts/checks/reports/junit.py` validates against
  (`xmllint --schema junit-10.xsd --noout`). Its `<testsuites>` root defines no
  `skipped` attribute, so an aggregate `skipped` there is a schema violation;
  the root-level skipped total is instead an arithmetic invariant the checker
  recomputes from the child `<testsuite>` elements.

## `surefire-test-report.xsd` — provenance only

- Source: the Maven Surefire plugin's published schema at
  `https://maven.apache.org/surefire/maven-surefire-plugin/xsd/surefire-test-report.xsd`
  (schema `version="3.0.2"`, read from the file's own `<xs:schema>` element).
- License: **Apache License, Version 2.0** — read from the file's header
  comment ("Licensed to the Apache Software Foundation (ASF) ... under the
  Apache License, Version 2.0").
- Role: kept alongside the validation schema strictly as tag-name provenance
  for the `flakyFailure`/`rerunFailure`/`rerunError`/`flakyError` element
  names and their `stackTrace`/`system-out`/`system-err` content model. It is
  **not** used for validation — it defines a single `<testsuite>` root (no
  `<testsuites>` wrapper), so a multi-suite document does not validate against
  it at all.
