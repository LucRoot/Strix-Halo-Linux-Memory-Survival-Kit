# Diagnosis: KFD Thrash vs VRAM Exhaustion vs I/O Starvation

A model load on a Strix Halo box is "hanging". Three completely
different problems produce that symptom, and the fix for each makes the
others worse if you guess wrong. This page is the triage flow. Every
check is read-only and runnable by anyone with shell access.

| | KFD thrash | VRAM exhaustion | I/O starvation |
|---|---|---|---|
| Loader CPU | 100% one core, **userspace** | low, mostly sleeping | low, in **D state** (uninterruptible) |
| GPU activity | **idle** while loader spins | busy (uploads/compute retry) | idle, waiting on reads |
| `journalctl -k` | `restore_userptr_worker` hog counts, `SVM mapping failed` | OOM / allocation failure lines from llama.cpp, not kernel | mostly quiet; maybe ata/nvme errors |
| Swap | in use and growing | not necessarily | not necessarily |
| Fix | relieve RAM pressure + `memory.low` budgets; reboot if counts are astronomical | smaller quant / lower `-c` / `-ngl` for fewer layers | move model to faster storage; drop page cache pressure |

## Step 0 — get the loader's PID

```bash
pgrep -af llama-server
# pick the one whose -m matches the model that's loading
PID=<pid>
```

## Step 1 — what is the process doing? (10 seconds)

```bash
top -b -n1 -p $PID | tail -2
# or, with more detail:
pidstat -p $PID 2 3
```

Read the columns:

- **`%usr` ~100, `%sys` ~0, one thread** → spinning in user code. Points
  at KFD thrash (see case study: the loader retries a GPU operation
  that keeps failing underneath it).
- **State `D`** (uninterruptible sleep), `%iowait` high on the system →
  I/O starvation. The loader is parked in a read it can't complete.
- **State `S`, near-zero CPU** → waiting on something. Keep digging.

Confirm with `/proc` directly (works everywhere, no extra tools):

```bash
grep -E '^(State|VmRSS|voluntary_ctxt_switches|nonvoluntary_ctxt_switches)' /proc/$PID/status
sleep 5
grep -E '^(State|VmRSS|voluntary_ctxt_switches|nonvoluntary_ctxt_switches)' /proc/$PID/status
```

- Context-switch counts **barely move** and `State` stays `R` →
  userspace spin, not waiting on the kernel.
- `nonvoluntary_ctxt_switches` climbing fast → being descheduled under
  pressure, not spinning.
- `VmRSS` frozen for minutes during a "load" → no progress, whatever
  the cause.

## Step 2 — is the GPU busy while the loader hangs?

```bash
rocm-smi --showuse
# or watch it:
watch -n2 rocm-smi --showuse
```

- **GPU idle (0–5% use, clocks low) while the loader burns CPU** → the
  loader is not stalled on GPU work. KFD thrash signature.
- **GPU busy** → real work is happening, just slowly. Check I/O next.

## Step 3 — what does the kernel say?

```bash
journalctl -k --since '24 hours ago' | grep -iE 'restore_userptr|SVM mapping|amdgpu.*fail'
```

- `amdgpu_amdkfd_restore_userptr_worker ... hogged CPU for >10000us N
  times` with **N growing day over day** → KFD thrash, full stop. This
  is the early-warning line; see
  [KFD_CASE_STUDY.md](KFD_CASE_STUDY.md) for the growth pattern
  (16,387 → 262,147 over four days on our box).
- `amdgpu: SVM mapping failed, exceeds resident system memory limit` →
  the GPU's resident working set hit the kernel cap; you are at or past
  the edge of what this box can hold. Relieve pressure now.

## Step 4 — rule in/out VRAM exhaustion

"VRAM" on a Strix Halo is the GTT carve-out plus whatever the driver
can spill into system RAM, so exhaustion here usually shows up in
userspace, not the kernel:

```bash
# llama.cpp logs its allocations; look for:
journalctl -u llama-26b.service --since today | grep -iE 'out of memory|failed to allocate|ggml'
```

- Explicit allocation failures from llama.cpp/ggml → VRAM exhaustion.
  Fix: smaller quant, lower context (`-c`), fewer GPU layers (`-ngl`),
  or evict another model.
- No allocation errors, but kernel lines from step 3 → it's not VRAM,
  it's reclaim/KFD.

## Step 5 — rule in/out I/O starvation

```bash
iostat -xz 5 3        # sysstat package
# look at the device holding your models: %util ~100, high await
```

Also compare load throughput against a known-good baseline. Our
reference point: a healthy box uploads this model family's layers at a
steady clip and finishes a 26B load in **71 s**; during the incident
the same load managed ~13 GB in ~10 minutes and then stalled entirely.
Slow *and steady* suggests storage; slow *then frozen with a spinning
CPU* suggests KFD.

## Decision table

| Evidence | Diagnosis | Action |
|---|---|---|
| userspace spin + GPU idle + `restore_userptr` hog counts | KFD thrash | apply `memory.low` budgets ([CGROUP_BUDGETS.md](CGROUP_BUDGETS.md)); if counts are already huge, reboot — see case study for why userspace fixes can't unwind it |
| llama.cpp allocation errors, no kernel noise | VRAM exhaustion | reduce footprint (quant/`-c`/`-ngl`), free another model |
| D state + `%util` 100 on model disk + no kernel noise | I/O starvation | faster storage for GGUFs, stop competing reads, `vm.drop_caches` only if page cache is the competitor |

## The one-line monitor

```bash
journalctl -k --since today | grep -c 'restore_userptr_worker.*hogged CPU'
```

Nonzero → look. Growing daily → act before loads start failing.
