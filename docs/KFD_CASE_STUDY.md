# KFD Thrash: A Case Study

How a Strix Halo inference box degraded over 12 days from "loads in 71 s"
to "loads never finish", what the kernel was telling us the whole time,
and how we proved the fix.

**Hardware/software context:** AMD Strix Halo APU (gfx1151), 128 GB
unified memory, ROCm 7.2.2, llama.cpp `llama-server` ROCm build, 7 model
services under systemd, kernel messages via `journalctl -k`.

All kernel-log lines below are quoted verbatim from `journalctl -k`.
Nothing is paraphrased or embellished.

---

## Background: why this failure mode is APU-specific

On Strix Halo there is no discrete VRAM. The GPU's address space is
backed by the same system RAM everything else uses. Two kernel
mechanisms sit on the critical path:

- **SVM (Shared Virtual Memory) / userptr mappings.** The KFD (Kernel
  Fusion Driver, `drivers/gpu/drm/amd/amdkfd/` in the kernel tree) maps
  userspace allocations into the GPU's page tables. The kernel caps how
  much can be resident; exceeding it fails the mapping.
- **MMU notifiers + the restore worker.** When the kernel's memory
  reclaim decides to evict pages that back a GPU mapping, an MMU
  notifier invalidates the GPU-side mapping. KFD queues
  `amdgpu_amdkfd_restore_userptr_worker` to rebuild it on next GPU
  access. Under sustained memory pressure this becomes a teardown /
  rebuild loop — the worker burns CPU, the GPU makes no forward
  progress, and user space waits (or spins).

Relevant kernel references:

- `Documentation/gpu/amdgpu/index.rst` — upstream AMDGPU/KFD docs
  entry point.
- `drivers/gpu/drm/amd/amdkfd/kfd_svm.c` — SVM range handling,
  eviction and restore logic (read the source; the restore worker is
  scheduled from the MMU-notifier invalidation path).
- `Documentation/admin-guide/cgroup-v2.rst`, section *Memory* —
  `memory.low` / `memory.high` / `memory.max` reclaim semantics. These
  are the knobs the fix is built on; see
  [CGROUP_BUDGETS.md](CGROUP_BUDGETS.md).

The practical consequence: **on a unified-memory APU, the OOM-killer is
not your worst case.** Your worst case is the state *before* the
OOM-killer fires — sustained reclaim pressure that keeps the box
"alive" while the GPU subsystem thrashes and every model load silently
fails. `memory.max` only caps usage; it does nothing to protect the
GPU's working set from reclaim. That is what `memory.low` is for.

## Timeline

### Jul 4 — SVM mapping failures

The first symptom, a burst of identical kernel lines:

```
Jul 04 18:18:52 hostname kernel: amdgpu: SVM mapping failed, exceeds resident system memory limit
```

At this point models still load, but the GPU can no longer keep its
full working set resident. Reclaim pressure starts evicting
userptr-backed pages.

### Jul 4–7 — the restore worker starts hogging CPU, doubling daily

```
Jul 04 23:05:35 workqueue: amdgpu_amdkfd_restore_userptr_worker [amdgpu] hogged CPU for >10000us 16387 times
Jul 05 04:15:47 ... 32771 times
Jul 05 13:04:41 ... 65539 times
Jul 06 06:06:58 ... 131075 times
Jul 07 17:49:09 ... 262147 times
```

Count of `>10000us` hog events: 16,387 → 32,771 → 65,539 → 131,075 →
262,147. Doubling roughly every day. The kernel is telling you, in
plain text, that the KFD restore path is running continuously. This
pattern — exponential growth in a workqueue-hog counter — is the
signature of a teardown/rebuild loop, not a one-off slow operation.

### Jul 11 — four failed loads of the same 26B model

Four consecutive attempts to load the same model (same binary, same
GGUF, same systemd unit that had worked for weeks). Common signature
across all four:

- **Last log output:** model metadata parse + tokenizer warnings, then
  silence. No "model loaded" line, ever.
- **VRAM:** ~13 GB uploaded over ~10 minutes — far slower than normal —
  then nothing. (The model is larger than that; the upload stalls.)
- **Process state:** 100% userspace CPU on a single core, near-zero
  syscalls and page faults, and — the tell — it keeps burning CPU even
  during windows where the GPU is completely idle.
- One instance ran until we killed it. systemd's accounting line:

  ```
  Consumed 51min 14.216s CPU time over 52min 10.480s wall clock
  ```

  i.e. ~98% of one core for 52 minutes, zero useful output.

**Baseline for comparison:** the identical load (same binary, model,
unit) completed in **71 s** on Jul 10, one day earlier.

### Diagnosis: userspace spin vs syscall wait

The method that separated "KFD thrash" from "slow disk" or "not enough
VRAM" — details and copy-paste commands in
[DIAGNOSIS.md](DIAGNOSIS.md):

1. `top`/`pidstat`: process pinned at 100% of **one** core, in
   userspace (`%usr`, not `%sys`, not `%iowait`).
2. `/proc/<pid>/status`: context-switch counts barely move between
   samples seconds apart; `VmRSS` static.
3. `/proc/<pid>/syscall`: the process is *not* parked in a blocking
   syscall — it's executing user code.
4. GPU monitoring: GPU idle while the loader burns CPU. A genuine
   upload or compute stall keeps the GPU busy; this doesn't.
5. `journalctl -k | grep restore_userptr`: the hog counts above.

Conclusion: the loader was not waiting on the kernel or the disk. It
was spinning in userspace — the classic shape of a retry loop around a
GPU operation that keeps failing underneath it because the KFD is
tearing mappings down as fast as they are rebuilt.

### Remediation and proof (Jul 11)

The box had **12 days of uptime and 26 GB of swap in use**. We rebooted
— not as a superstition, but because 12 days of evict/restore churn had
left the KFD and the page cache in a state no userspace action could
reset.

Post-reboot, identical conditions (same binary, same model file, same
unit):

- `model loaded` in **37.7 s**, health endpoint returns 200.
- Swap: **26 GB → 0**.

37.7 s vs 52 min of spinning for the exact same load. The variable was
host memory state, nothing else.

## What we changed so it doesn't recur

1. **cgroup budgets with `memory.low` protection on every inference
   service** — so reclaim pressure on one model can't evict another
   model's (or the GPU's) working set. Values and rationale:
   [CGROUP_BUDGETS.md](CGROUP_BUDGETS.md).
2. **A boot-time fleet-state assertion** — the reboot surfaced two
   latent config bugs (a missing `enable` symlink, a service user whose
   home directory wasn't traversable). Now checked on every boot:
   [../scripts/fleet-state-assert.sh](../scripts/fleet-state-assert.sh).
3. **A triage habit**: a load that hangs gets diagnosed via
   [DIAGNOSIS.md](DIAGNOSIS.md) before anyone reaches for
   `systemctl restart`. Restarting a thrashing box without fixing
   memory pressure just re-enters the loop.

## Monitoring hook

If you run a fleet on a Strix Halo box, alert on this one line:

```bash
journalctl -k --since today | grep -c 'restore_userptr_worker.*hogged CPU'
```

Any nonzero count deserves a look. A count that grows day over day is
the early-warning signal in this case study — we had a week of warning
before the first failed load, and ignored it. Don't.
