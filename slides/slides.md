---
marp: true
theme: default
paginate: true
---

<!-- Render: npx @marp-team/marp-cli slides.md --pdf  (or --pptx) -->

# Why was our test bill so high?

### A real project: 59 billable minutes per run → 20

<!--
Every number comes from the GitHub Actions API. No platform dropped, no test deleted.
-->

---

# The setup

- A small C++ library with a Python wrapper
- Shipped on **Linux, macOS and Windows**
- **CI** = a robot that builds and tests the code on all three, every time you push
- Every robot-minute costs money, and some platforms cost more than others

**Cost: about 59 billable minutes per run**

<!--
Why three platforms: two bugs had only appeared on Windows, and could never have failed on a developer's Mac.
-->

---

# 🤔 Pause and guess

**One Windows job took 754 seconds (about 12.5 minutes).**

It does three things:

1. Compile the C++ library
2. Run the tests
3. Install the Python packages the tests need

### Which one took the most time? What share of the 754 s?

*(Pause the video and think before you continue.)*

---

# Where did the time go?

**Before: time spent in each CI job**

| Job | Total job time | Installing dependencies |
|---|---:|---:|
| Windows | 754 s | **706 s** |
| Ubuntu (Linux) | 323 s | 309 s |
| Ubuntu + KenLM (Linux) | 408 s | 293 s |
| macOS | 71 s | 58 s |

Installing dependencies took a large share on every job, but the
**Windows install was the longest**.

<!--
Each row is a separate job; these jobs can run in parallel. KenLM is an extra language-model dependency tested in a separate Linux job.
-->

---

# The answer

**Windows job: 754 seconds**

```
Install dependencies  ██████████████████████████████████▌  706 s  (94%)
Compile library       █                                      22 s
Run tests             ▏                                       5 s
Everything else       █                                      21 s
```

The slowest step was not the one the job is named after.

<!--
Same pattern on every job: Ubuntu 96%, macOS 82%, Ubuntu + KenLM 72%.
-->

---

# The obvious fix

An AI assistant's first suggestion was to **cut a platform**.

I asked it to **measure first**.

The data showed **94% of the time was one dependency install.**

<!--
The point is not that the AI was bad. Any of us, or a teammate, might reach for the obvious fix. Measure before you act.
-->

---

# Why was installing so slow?

1. The tests compare our library against another one: `pyctcdecode`
2. `pyctcdecode` requires an **old NumPy** (below version 2)
3. That old NumPy has **no ready-made Windows download** for our Python version
4. So pip **builds NumPy from source: about 12 minutes**
5. …and the result crashed when imported

🔁 The project existed to **get rid of** `pyctcdecode`.
The dependency being deleted was 94% of the cost of testing its replacement.

---

# The fix: install only what each job needs

The comparison tool is only needed by the tests that **compare**.
The Windows job just proves: it builds, it's named right, it loads, it decodes.

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

- Install it on **Linux only**, where ready-made downloads exist
- On other platforms those tests skip; **21 of 47 tests** still run

---

# Did the other jobs get faster too?

| Job | Before | After | Time saved |
|---|---:|---:|---:|
| Ubuntu (Linux) | 323 s | 45 s | 278 s |
| Ubuntu + KenLM (Linux) | 408 s | 156 s | 252 s |
| Windows | 754 s | 128 s | **626 s** |
| macOS | 71 s | 17 s | 54 s |

**Yes: all four jobs were faster in the recorded runs.**
All platforms remain; comparison tests now run on Linux.

<!--
These are individual job durations from one before run and one after run, not the elapsed time of the entire workflow. The changes included dependency installation and caching; the measurements do not isolate the effect of each change.
-->

---

# The billing twist

GitHub **rounds each job up to a whole minute, then multiplies**:

| Runner | Multiplier |
|---|---|
| Linux | ×1 |
| Windows | ×2 |
| macOS | **×10** |

macOS now does **17 seconds** of work → billed **10 minutes**.

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

# Three cheap fixes anyone can make

**1. Don't run twice for the same commit.** A branch listed by name *and* with a pull request ran the full matrix twice.

**2. Cancel outdated runs.** Pushing 3 times in a row ran 3 full matrices.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**3. Cache downloads.** Reuse what was already built instead of rebuilding.

---

# Lessons

1. **Measure before you change anything**: the answer was invisible until we looked
2. **A slow step is often a design signal**, not just a tuning problem
3. **Know the billing model** or you'll tune the wrong number
4. **Split "the tests" by what they need**, not by folder

⚠️ One project. The 94% is not a law; **the method is what transfers.**

*Method: `measure.sh`, three `gh api` calls that work on any repo.*

---

# A mistake worth keeping

```
numpy==2.2.1
pyctcdecode==0.5.0    # requires numpy<2
```

These contradict. pip refuses the whole install.

- 3 of 4 jobs passed (they installed in separate commands)
- Only the job that used the file failed
- **CI caught it.** That's the argument for having CI.

---

# Try it yourself

- Repo: https://github.com/aanchan/ci-cost-case-study
- `workflows/before.yml` and `workflows/after.yml`: the real files
- `data/timings.json`: raw data for both runs

**Exercise:** from the JSON, compute the billable minutes for the Windows job *before*.
*(Hint: seconds → round up to minutes → multiply.)*

**Discuss:** where could a hidden slow step be costing *your* project?
