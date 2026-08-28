#requires -Version 7.0
$ErrorActionPreference = 'Stop'

# Disabled 2026-08-28 — see .githooks/pre-push for the full writeup.
# This used to force-mirror every `git push origin` to two Cambridge
# corporate repos and silently excluded CarlDog/certmate.git from push
# targets once triggered. Cleaned up after an accidental full-history
# push to those repos; see CLAUDE memory certmate-security-risk.md.

exit 0
