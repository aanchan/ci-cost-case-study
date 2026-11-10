---
marp: true
theme: default
paginate: true
---

<!-- Render: npx @marp-team/marp-cli slides.md --pdf  (or --pptx) -->

# Reducing the Cost of Continuous Integration

A case study in measuring and improving a cross-platform build.

The estimated cost per workflow run fell from 59 to 20 billable minutes.

<!--
The job durations come from the GitHub Actions API; billable minutes are estimates based on those durations. No platform was dropped and no test was deleted.
-->

---

# Project and CI Workflow

The project is a C++ library with a Python interface that supports Linux, macOS, and Windows.

Continuous integration (CI) automatically builds and tests the software when code changes. The workflow runs separate jobs on each operating system, plus an additional Linux job with a language-model dependency.

The initial workflow consumed an estimated 59 billable minutes per run.

<!--
Why three platforms: two bugs had only appeared on Windows, and could never have failed on a developer's Mac.
-->

---

# Pause and Consider

The Windows job took 754 seconds, or approximately 12.5 minutes.

The job performed three activities:

- It installed Python dependencies.
- It compiled the C++ library.
- It ran tests.

**Which activity took the most time, and what proportion of the job did it account for?**

Pause the video and consider your answer before continuing.

---

# Where Was Time Spent?

The following measurements show the duration of each job before the changes.

| Job | Total job time | Installing dependencies |
|---|---:|---:|
| Windows | 754 s | **706 s** |
| Ubuntu (Linux) | 323 s | 309 s |
| Ubuntu + KenLM (Linux) | 408 s | 293 s |
| macOS | 71 s | 58 s |

Installing dependencies accounted for a substantial share of each job. The Windows installation took the longest.

<!--
Each row is a separate job; these jobs can run in parallel. KenLM is an extra language-model dependency tested in a separate Linux job.
-->

---

# The Windows Job in Detail

The Windows job took 754 seconds in total.

| Activity | Duration |
|---|---:|
| Installing dependencies | 706 s (94%) |
| Compiling the library | 22 s |
| Running tests | 5 s |
| Other steps | 21 s |

Dependency installation, rather than compilation or testing, accounted for most of the job.

<!--
Same pattern on every job: Ubuntu 96%, macOS 82%, Ubuntu + KenLM 72%.
-->

---

# Choosing an Approach

An AI assistant initially suggested removing a platform from the workflow.

I asked it to measure the workflow first. The measurements showed that dependency installation accounted for 94% of the Windows job.

This evidence suggested an opportunity to reduce the cost without removing a platform.

<!--
The purpose is to illustrate why a proposed optimization should be evaluated against measurements before it is adopted.
-->

---

# Why Was Dependency Installation Slow?

Some tests compare the library with a reference implementation called `pyctcdecode`, which requires a version of NumPy older than 2.0.

For Python 3.13 on Windows, that older NumPy version had no prebuilt package. The package installer therefore built it from source, which took several minutes. In a separate observed failure, the resulting NumPy installation also crashed on import.

The project was intended to replace `pyctcdecode`, yet installing it dominated the Windows CI job.

---

# Limiting Dependencies to the Jobs That Need Them

Only the comparison tests require the reference implementation. The workflow was changed to install it on Linux and skip those tests when it is unavailable.

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

On Windows and macOS, 21 of the 47 tests still run. These jobs continue to check that the library builds, loads, and decodes.

---

# Job Durations Before and After

| Job | Before | After | Time saved |
|---|---:|---:|---:|
| Ubuntu (Linux) | 323 s | 45 s | 278 s |
| Ubuntu + KenLM (Linux) | 408 s | 156 s | 252 s |
| Windows | 754 s | 128 s | **626 s** |
| macOS | 71 s | 17 s | 54 s |

All four jobs were faster in the recorded runs. All platforms remain in the workflow, while comparison tests run on Linux.

<!--
These are individual job durations from one before run and one after run, not the elapsed time of the entire workflow. The changes included dependency installation and caching; the measurements do not isolate the effect of each change.
-->

---

# Accounting for Platform Multipliers

The case study estimates billable minutes by rounding each job up to a whole minute and applying a platform multiplier.

| Runner | Multiplier |
|---|---|
| Linux | ×1 |
| Windows | ×2 |
| macOS | **×10** |

Under this model, the 17-second macOS job is estimated at 10 billable minutes.

---

# Estimated Billable Minutes

The table applies the case study's rounding and multiplier model to each recorded job.

| Job | Billable before | Billable after |
|---|---|---|
| Ubuntu | 6 | 1 |
| Ubuntu + KenLM | 7 | 3 |
| Windows | 26 | 6 |
| macOS | 20 | 10 |
| **Total** | **59** | **20** |

<!--
Worked example: Windows before = 754 s → 13 min → ×2 = 26. macOS after = 17 s → 1 min → ×10 = 10. Going below one minute on macOS saves nothing. The only lever left is running it less often.
-->

---

# Additional Workflow Changes

The workflow was also changed to avoid duplicate runs for commits that triggered both a branch push and a pull request.

Concurrency settings cancel an earlier run when a newer run in the same group starts:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Dependency caching allows previously downloaded or built packages to be reused.

---

# Conclusions

1. Measure individual CI steps before deciding what to optimize.
2. Examine whether a slow dependency is necessary for every job.
3. Consider the billing model as well as elapsed time.
4. Organize tests and dependencies according to what each job needs.

This case study concerns one project. Its measurements should not be generalized, but its method can be applied elsewhere.

---

# A Dependency Conflict

```
numpy==2.2.1
pyctcdecode==0.5.0    # requires numpy<2
```

These requirements are incompatible: `pyctcdecode` requires NumPy below version 2, while the file pins version 2.2.1. Pip cannot resolve both requirements in a single installation.

Three of the four jobs passed because they installed the packages separately. The job that used the requirements file failed, allowing CI to expose the conflict.

---

# Examining the Evidence

The repository is available at https://github.com/aanchan/ci-cost-case-study.

The `workflows/before.yml` and `workflows/after.yml` files show the workflow changes. The `data/timings.json` file contains the recorded job and step durations.

**Exercise:** Use the JSON data to calculate the estimated billable minutes for the Windows job before the changes. Round the duration up to whole minutes, then apply the Windows multiplier.

Consider where a similarly slow step might occur in another project.
