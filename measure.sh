#!/usr/bin/env bash
# Measure where a GitHub Actions run's time and money go.
#
# Point it at any repository and run id. Everything in this repository's README
# came out of these three commands — the method is the transferable part, not
# the numbers.
#
#     ./measure.sh OWNER/REPO RUN_ID
set -euo pipefail

REPO="${1:?usage: measure.sh OWNER/REPO RUN_ID}"
RUN="${2:?usage: measure.sh OWNER/REPO RUN_ID}"

echo "== Wall time per job"
gh api "repos/$REPO/actions/runs/$RUN/jobs" --jq '
  .jobs[] | "  \(.conclusion // .status)\t\(((.completed_at|fromdate) - (.started_at|fromdate)))s\t\(.name)"'

echo
echo "== Steps taking over 20 seconds"
# Where the time actually goes. It is rarely the step the job is named after.
gh api "repos/$REPO/actions/runs/$RUN/jobs" --jq '
  .jobs[] | "  === \(.name)",
  (.steps[] | select(.completed_at != null
      and (((.completed_at|fromdate) - (.started_at|fromdate)) > 20))
   | "        \(((.completed_at|fromdate) - (.started_at|fromdate)))s  \(.name)")'

echo
echo "== Billable minutes, per platform multiplier"
# GitHub rounds each job up to the whole minute, then multiplies. macOS at 10x
# against a one-minute floor means a 17-second job is billed as ten minutes —
# which is why knowing the billing model comes before optimising for it.
gh api "repos/$REPO/actions/runs/$RUN/jobs" --jq '
  [.jobs[] | {
     name,
     seconds: ((.completed_at|fromdate) - (.started_at|fromdate)),
     multiplier: (if (.name | test("macos")) then 10
                  elif (.name | test("windows")) then 2
                  else 1 end)
   }]
  | (.[] | "  \(.name)\t\(.seconds)s\tx\(.multiplier)\t\((.seconds / 60 | ceil) * .multiplier) min"),
    "  ----",
    "  TOTAL\t\t\t\(map((.seconds / 60 | ceil) * .multiplier) | add) billable min"'

echo
echo "== What GitHub itself reports as billable"
# Often zeroes while a run settles, or while inside an included allowance.
gh api "repos/$REPO/actions/runs/$RUN/timing" --jq '
  .billable | to_entries[] | "  \(.key): \(.value.total_ms / 60000) min across \(.value.jobs) job(s)"'
