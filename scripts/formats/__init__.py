"""Shared library for mtest's machine-readable report formats.

Parsers, validators and the outcome vocabulary that the gates under
`scripts/checks/`, `scripts/qa/` and `scripts/e2e/` all consume. Two modules
also carry a gate entry point of their own, run as `junit-check`
(`junit.py`) and `junit-render-check` (`junit_render.py`).
"""
