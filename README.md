# Cutting a CI bill by two thirds, without cutting coverage

A worked example from a real project, with the measurements that drove each
decision. Every number here came from the GitHub Actions API on an actual
repository, not from a benchmark built to make a point.

**59 billable minutes per run → 20.** No platform dropped, no test deleted.

The interesting part is not the number. It is that the answer was invisible
until it was measured, and that the largest cost turned out to be a dependency
the project existed to delete.

---

## The setting

A small C++ library with a Python binding, shipped to macOS, Linux and Windows.
CI was added late, for a specific reason: two defects had been found by a
reviewer *reading* the build file rather than by anything running.

Both were packaging faults. On Windows the library was built as
`libctc_beam_decoder.dll` while the loader looked for `ctc_beam_decoder.dll`,
and a multi-config generator put it in a `Release/` subdirectory nothing
searched. Neither could fail on the developer's Mac — not "didn't", *couldn't*.
That is what a platform matrix is for.

So the workflow was four jobs: Linux, macOS, Windows, and a second Linux job
that additionally builds a C++ dependency from source.

It was correct. It was also costing about 59 billable minutes a run.

---

## Step 1: measure before changing anything

The instinct on being told CI is expensive is to remove a platform. Resist it
for ten minutes and ask where the time goes.

```bash
# Wall time per job
gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs \
  --jq '.jobs[] | "\(.name): \(((.completed_at|fromdate) - (.started_at|fromdate)))s"'

# Wall time per step, for steps over 20 seconds
gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs --jq '
  .jobs[] | "=== \(.name)",
  (.steps[] | select(.completed_at != null
    and (((.completed_at|fromdate) - (.started_at|fromdate)) > 20))
   | "    \(((.completed_at|fromdate) - (.started_at|fromdate)))s  \(.name)")'
```

The result was lopsided enough to make the next step obvious:

| job | total | slowest step | share |
|---|---|---|---|
| windows | 754s | Install test dependencies — 706s | **94%** |
| ubuntu | 323s | Install test dependencies — 309s | **96%** |
| ubuntu + C++ dep | 408s | Install test dependencies — 293s | 72% |
| macos | 71s | Install test dependencies — 58s | 82% |

Compiling the library took 13–22 seconds. Running the tests took 2. Everything
else was `pip install`.

**Lesson: the expensive thing is rarely the thing the job is named after.**

---

## Step 2: read the log for the slow step

`pip install --quiet` hid what it was doing. Unhidden, the Windows job was
building **numpy from source for ten minutes** — and then numpy crashed on
import, inside its own `getlimits.py`.

The chain:

1. Tests compare against a reference implementation, `pyctcdecode`.
2. `pyctcdecode` pins `numpy<2.0.0`.
3. numpy 1.26 publishes no Windows wheel for Python 3.13.
4. So pip compiles it, slowly, and the result fails its own floating-point
   checks on that toolchain.

That defect is the reason the library in question was written: to remove
`pyctcdecode` from the project. **The dependency being deleted was 94% of the
cost of testing its replacement.**

**Lesson: a slow CI step is often a design signal, not a tuning problem.**

---

## Step 3: install what each job actually needs

The reference implementation is needed only by the tests that *compare against
it*. The Windows job's purpose is packaging — does the library build, is it
named what the loader expects, does it land where the loader searches, does it
survive installation, does it load, does it decode. None of that needs a
reference.

So the tests were made to skip when it is absent, and it is installed on Linux
only, where wheels exist.

```python
try:
    import pyctcdecode
except ImportError:
    pyctcdecode = None

needs_reference = pytest.mark.skipif(
    pyctcdecode is None,
    reason="comparison tests need something to compare with",
)
```

21 of 47 tests still run without it — and they run on **numpy 2.5.1**, which
is the project's own argument restated as a test run.

Windows: **754s → 128s.** Its ×2 multiplier turns 26 billable minutes into 6.

**Lesson: "the test suite" is not one thing. Split it by what it needs, not by
what directory it lives in.**

---

## Step 4: the multipliers, which change what is worth optimising

GitHub bills minutes, then multiplies by platform, then rounds each job up to
the whole minute.

| runner | multiplier |
|---|---|
| Linux | ×1 |
| Windows | ×2 |
| macOS | **×10** |

That last row reshapes the problem. After the fix, the macOS job does 17
seconds of work and is billed for **ten minutes** — one minute rounded up,
times ten. It is now the most expensive job in the matrix by a wide margin,
while being the fastest.

Two consequences worth teaching:

- Optimising a macOS job below one minute buys nothing. The floor is the floor.
- The only remaining lever there is *frequency* — run it on merges rather than
  on every push — not duration.

**Lesson: know the billing model before optimising, or you will tune the wrong
number.**

---

## Step 5: three cheap structural fixes

These are not about any one job.

**Triggers.** The workflow listed feature branches by name *and* ran on pull
requests. A branch that was both produced two full matrix runs for one commit —
double cost, identical answer. Worse, the list needed editing whenever a branch
appeared, so a branch nobody remembered to add got no checks at all.

```yaml
# before
on:
  push:
    branches: [main, feature-a, feature-b]
  pull_request:

# after
on:
  push:
    branches: [main]
  pull_request:        # any branch, no maintenance
  workflow_dispatch:
```

**Concurrency.** Fixing a red build means pushing several times in a row. Each
push started a full matrix and every one ran to completion, though only the
last answer mattered. Three were in flight at once at one point.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**Caching.** `actions/setup-python` can cache pip, but it needs a file to hash
for the key. Adding a pinned requirements file gives it one, so a compiled
wheel is reused rather than rebuilt.

**Lesson: the structural fixes are cheaper to make than the clever ones, and
usually pay more.**

---

## The result

| job | before | after | billable before | billable after |
|---|---|---|---|---|
| ubuntu | 323s | 45s | 6 | 1 |
| ubuntu + C++ dep | 408s | 156s | 7 | 3 |
| windows | 754s | 128s | 26 | 6 |
| macos | 71s | 17s | 20 | 10 |
| **total** | | | **59** | **20** |

Against a 2,000-minute monthly allowance that is roughly 34 runs a month
becoming 100 — before counting the duplicate runs that no longer happen and the
superseded runs that now get cancelled.

`workflows/before.yml` and `workflows/after.yml` are the two files as they
actually were. `data/timings.json` is the raw API output for both runs, so the
table above can be recomputed rather than trusted.

---

## A mistake worth keeping

Partway through, the requirements file looked like this:

```
numpy==2.2.1
pyctcdecode==0.5.0    # requires numpy<2
```

Those contradict. Pip does not quietly downgrade a hard pin — it refuses the
entire resolution with `ResolutionImpossible`. The comment written beside it
even described the contradiction as though pip would work around it.

Three of the four jobs passed, because they installed the two packages in
separate commands, where pip *will* downgrade. Only the job using the file
directly failed.

Two things to take from it. The fix was to express the constraint as
installation *order* rather than as a hope. And the check that caught it was
CI itself — which is the argument for having it, made at the author's expense.

---

## What this example does not show

Being clear about the limits, since a case study invites over-generalising:

- The corpus is one project. The 94% figure is not a law; the *method* of
  finding it is the transferable part.
- Nothing here addresses test runtime, which was already trivial (2 seconds).
  A project whose tests genuinely take twenty minutes needs different answers.
- Self-hosted runners, larger runners and matrix pruning by changed paths are
  all untouched levers.
- The biggest saving came from a dependency this project was already removing
  for other reasons. That is luck as much as method — though noticing it was
  not.
