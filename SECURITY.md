# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Published releases | None yet |

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/mikeleppane/mtest/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include:

- the affected mtest version, the platform, and the Mojo version
- reproduction steps, or a minimal test project
- the impact, and any workaround you know of

Reports stay private while a fix and disclosure are coordinated. The project
does not promise a fixed response time.

## Execution model

mtest compiles and runs test code with the invoking user's privileges. It is a
test runner, not a sandbox. Reports about unintended command construction, path
handling, process supervision, package integrity, or privilege-boundary
behavior are still in scope.
