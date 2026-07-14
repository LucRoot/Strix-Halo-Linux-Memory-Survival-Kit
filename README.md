# APU Memory Survival Kit

Operational kit for running a **multi-model local inference fleet on a
unified-memory APU** (AMD Strix Halo / gfx1151, tested on ROCm 7.2.2 with
llama.cpp) without the machine slowly strangling itself.

Everything here was earned the hard way on a 128 GB Strix Halo box serving
7+ llama.cpp model instances concurrently. The failure mode it prevents is
specific to unified-memory APUs and it is nasty:

> **System RAM pressure → the kernel evicts the GPU's userptr-backed
> mappings → the KFD MMU-notifier restore worker thrashes → model loads
> spin in userspace forever instead of completing.**

On a dGPU box, RAM pressure hurts the CPU. On a Strix Halo, RAM pressure
*is* GPU pressure — the "VRAM" is carved out of the same physical memory
the kernel is trying to reclaim. Once the box starts swapping, GPU-side
mappings get torn down and restored over and over, and `llama-server`
loads that should take ~40 s never finish at all.

## What broke (short version)

- Jul 4: kernel log fills with `amdgpu: SVM mapping failed, exceeds
  resident system memory limit`.
- Jul 4–7: `amdgpu_amdkfd_restore_userptr_worker` CPU-hog warnings,
  count **doubling daily** (16,387 → 262,147).
- Jul 11: four consecutive loads of a 26B model never complete. One
  burned **51 min of single-core CPU time over 52 min of wall clock**
  and produced nothing. Baseline for the identical load: 71 s.
- Reboot (after 12 days uptime, 26 GB of swap in use): identical
  binary/model/unit loads in **37.7 s**.

Full evidence, verbatim journalctl lines, and the diagnosis method:
[docs/KFD_CASE_STUDY.md](docs/KFD_CASE_STUDY.md).

## Kit contents

| Path | What it is |
|---|---|
| `docs/KFD_CASE_STUDY.md` | Full incident timeline with verbatim kernel-log evidence, the userspace-spin vs syscall-wait diagnosis method, and the reboot remediation proof. |
| `docs/CGROUP_BUDGETS.md` | Per-service `MemoryMax`/`MemoryLow` budgeting with an illustrative value set (production values deliberately withheld — they encode the fleet's capacity plan), why `memory.low` (protection) matters more than `MemoryMax` (limit) on a unified-memory APU, and how to apply changes with `daemon-reload` — no restarts. |
| `docs/DIAGNOSIS.md` | Triage: how to tell "KFD thrash" from "VRAM exhaustion" from "I/O starvation" using only `/proc` and standard tools. |
| `scripts/apply-cgroup-budget.sh` | Applies MemoryMax/MemoryLow (and optional MemoryHigh/MemorySwapMax) to a systemd unit via drop-in + `daemon-reload`, without restarting the service. |
| `scripts/fleet-state-assert.sh` | Boot-time assertion script: verifies every fleet unit is enabled (symlink present) and that each service user's home directory is traversable. Born from the reboot fallout in the case study. |

## Quick start

```bash
# 1. Give every inference service a memory budget (no restart needed)
sudo scripts/apply-cgroup-budget.sh llama-26b.service --max 14G --low 4G

# 2. Add the boot-time assertion (runs after all fleet units)
sudo cp scripts/fleet-state-assert.sh /usr/local/sbin/fleet-state-assert
sudo chmod 755 /usr/local/sbin/fleet-state-assert
# then wire it into a oneshot unit — see docs/CGROUP_BUDGETS.md

# 3. When a load "hangs", don't restart blindly — triage first:
cat /proc/<pid>/status | grep -E 'VmRSS|voluntary_ctxt'
grep -c . /proc/<pid>/syscall 2>/dev/null   # see docs/DIAGNOSIS.md
journalctl -k | grep -i 'restore_userptr\|SVM mapping'
```

## Prerequisites

- systemd (cgroup v2 unified hierarchy — the default on every current distro)
- A Strix Halo / gfx1151 box with ROCm (developed against 7.2.2)
- Root for applying budgets; read-only diagnosis needs none

## Scope

This kit is about **host-level memory hygiene**: cgroup budgets, kernel
evidence, diagnosis, boot assertions. It does not cover llama.cpp build
flags or model serving configs — those live in the sibling repo
[Strix-Halo-Linux-Llama_cpp-ROCm](https://github.com/LucRoot/Strix-Halo-Linux-Llama_cpp-ROCm). If your loads hang and you found this repo
from there: start with [docs/DIAGNOSIS.md](docs/DIAGNOSIS.md).

## Environment

| Item | Value |
|---|---|
| CPU | AMD Strix Halo (gfx1151) |
| RAM | 128 GB unified system/GPU memory |
| OS | Linux distribution with systemd and cgroup v2 |
| ROCm | 7.2.2 |
| Runtime | llama.cpp server fleet, 7+ concurrent model instances |
| Target failure | KFD restore_userptr_worker thrash under system RAM pressure |

## Verification / testing

The scripts are designed to be safe to run on a live fleet:

1. **Cgroup budget application** — run `scripts/apply-cgroup-budget.sh` against a test unit (or use `--dry-run` if you add one) and verify the drop-in file is written under `/etc/systemd/system/` without restarting the service.
2. **Boot assertion** — copy `scripts/fleet-state-assert.sh` to `/usr/local/sbin/fleet-state-assert`, run it manually, and confirm it reports every expected unit as enabled and every service home directory as traversable.
3. **Diagnosis workflow** — follow `docs/DIAGNOSIS.md` to inspect `/proc/<pid>/status`, `/proc/<pid>/syscall`, and `journalctl -k` on a healthy box so you recognize the patterns before you need them in an incident.

## Known limitations

- **Single APU architecture.** The failure mode and mitigations are specific to unified-memory APUs (Strix Halo / gfx1151). dGPU systems experience different symptoms.
- **Production budget values are not included.** The illustrative values in `docs/CGROUP_BUDGETS.md` must be tuned to your fleet size, model sizes, and concurrency target.
- **Host-level only.** This kit does not tune llama.cpp build flags, model quantization, or serving topology.
- **Reboot is still the rescue.** The documented remediation for an active KFD-thrash state is a reboot; the kit prevents the condition, it does not unwind it once severe.
- **ROCm version lock.** Evidence was gathered on ROCm 7.2.2; later ROCm releases may change KFD behavior or log messages.

## Reproduction notes

Everything is intended to be reproducible from the included scripts and docs:

1. Clone the repository.
2. Read `docs/KFD_CASE_STUDY.md` for the full incident evidence and diagnosis method.
3. Read `docs/CGROUP_BUDGETS.md` and choose memory budgets for your fleet.
4. Apply budgets with `scripts/apply-cgroup-budget.sh`.
5. Install and wire up `scripts/fleet-state-assert.sh` as a boot-time oneshot unit.
6. Use `docs/DIAGNOSIS.md` when a load appears to hang.

## License

PolyForm Noncommercial 1.0.0 — see [LICENSE](LICENSE).

---

**Author:** Dr. Lucas Root, Ph.D. — [info@lucasroot.com](mailto:info@lucasroot.com)
