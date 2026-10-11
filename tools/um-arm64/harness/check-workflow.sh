#!/bin/bash
# Validate the workflows before pushing them, because a bad expression in a
# job-level `env:` does not fail one job -- it fails the entire run in 0s with
# "This run likely failed because of a workflow file issue" and *zero* jobs. CI
# therefore cannot report on the workflow CI could not read, and the only place
# to catch it is here.
#
# Two things have bitten this repository:
#
#   * A `runner` context in a job-level `env:`. Only `github`, `needs`,
#     `strategy`, `matrix`, `vars`, `secrets` and `inputs` exist there; `runner`
#     is step-scope, which is why `${{ runner.temp }}` in `jobs.<id>.env` is not
#     a syntax error to any linter that only parses YAML.
#
#   * A job with no `timeout-minutes`, which turns a hang into a six-hour run.
#
#   ./check-workflow.sh [workflow.yml ...]     # defaults to .github/workflows/*.yml
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$(cd "$HERE/../../.." && pwd)

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    shopt -s nullglob
    files=("$TREE"/.github/workflows/*.yml "$TREE"/.github/workflows/*.yaml)
    shopt -u nullglob
fi

[ "${#files[@]}" -gt 0 ] || { echo "check-workflow.sh: no workflows found" >&2; exit 2; }

python3 - "${files[@]}" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.exit("check-workflow.sh: needs pyyaml (python3 -m pip install pyyaml)")

# Available in a job-level env:, per GitHub's contexts table. `runner` is not.
JOB_ENV_CONTEXTS = {"github", "needs", "strategy", "matrix", "vars", "secrets", "inputs"}
STEP_ONLY = {"runner", "env", "steps", "job", "jobs", "inputs"}

problems = []
checked = 0

for path in sys.argv[1:]:
    with open(path) as fh:
        try:
            doc = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            problems.append(f"{path}: does not parse: {exc}")
            continue

    if not isinstance(doc, dict) or "jobs" not in doc:
        problems.append(f"{path}: no jobs")
        continue

    for name, job in (doc.get("jobs") or {}).items():
        checked += 1
        where = f"{path}: job '{name}'"

        if not isinstance(job, dict):
            problems.append(f"{where}: not a mapping")
            continue

        # A job that only calls a reusable workflow has no steps of its own.
        if "uses" not in job:
            if "timeout-minutes" not in job:
                problems.append(f"{where}: no timeout-minutes (a hang becomes six hours)")

        for key, value in (job.get("env") or {}).items():
            text = str(value)
            for ctx in STEP_ONLY:
                if f"{ctx}." in text or text.strip() == f"${{{{ {ctx} }}}}":
                    problems.append(
                        f"{where}: env {key} uses the '{ctx}' context, which does not "
                        f"exist at job scope -- this fails the whole run with zero jobs"
                    )
                    break

        # The same mistake one level down is legal, so only report job scope.

for p in problems:
    print(f"FAIL {p}")
if problems:
    sys.exit(1)

print(f"workflow OK ({checked} jobs checked)")
PY
