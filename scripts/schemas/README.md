# Vendored schemas

Every file here is vendored verbatim from upstream and is not modified.
Attribution for the JUnit schemas is read directly from each file's own header
comment; JSON Schema carries no header, so `recipe-format.schema.json` records
its exact upstream commit below.

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

## `recipe-format.schema.json` — validation dialect

- Source: `schema.json` from `prefix-dev/recipe-format` at commit
  `7e9363f2c7288b859c51e341a159fdfdd02bff79`. Pinned by commit because that
  project's tagged releases stop at `v0.9.3` (2024) while the schema
  rattler-build and modular-community reference is the one on `main`.
- License: **BSD 3-Clause "New" or "Revised" License**.
- Role: the schema `scripts/checks/community_recipe.py` validates both
  `recipe/recipe.yaml` and the rendered community recipe against
  (`check-jsonschema --schemafile recipe-format.schema.json`). It is vendored
  rather than fetched so the check stays hermetic, matching every other gate in
  this repository.
- Note: a forty-character all-digit `source[].rev` parses as a YAML integer and
  fails this schema's `string` requirement. Real commit SHAs are hex and
  effectively never all-digit, so the checker renders its schema probe with a
  SHA carrying a letter rather than quoting `rev` in the template.

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
