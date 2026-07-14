# cgroup Memory Budgets for a Multi-Model Fleet

How we budget RAM across 7+ llama.cpp services on one 128 GB Strix Halo
box so that memory pressure on any one model cannot start the
eviction/KFD-thrash cascade described in
[KFD_CASE_STUDY.md](KFD_CASE_STUDY.md).

Everything here uses **cgroup v2** semantics exposed through systemd.
References: `Documentation/admin-guide/cgroup-v2.rst` (kernel),
`systemd.resource-control(5)` (the `Memory*` properties below).

## The one idea that matters

On a unified-memory APU, `MemoryMax` alone is the wrong tool.

- `MemoryMax` (`memory.max`) is a **hard limit**. Cross it and the
  cgroup gets OOM-killed (or stalls). It protects the *rest of the
  system* from this service.
- `MemoryLow` (`memory.low`) is **reclaim protection**. The kernel will
  avoid reclaiming this cgroup's pages below the low watermark *unless
  it genuinely cannot find memory anywhere else*. It protects *this
  service's working set* from everyone else — and on a Strix Halo, the
  GPU's userptr-backed mappings live in exactly the pages reclaim would
  otherwise take.

The incident in the case study happened because nothing was protected:
once aggregate pressure pushed the box into reclaim, the kernel started
evicting GPU-backed pages from every model indiscriminately, and the
KFD restore worker ate the machine. `MemoryLow` on each service carves
the box into defended territories so pressure stays local to whoever
caused it.

Rule of thumb that falls out of this:

> **`MemoryMax` answers "how big may this model get before we kill it?"
> `MemoryLow` answers "how much of this model must never be evicted
> under pressure?" On a unified-memory APU, the second question is the
> important one.**

## Illustrative budgets

Genericized service names; values are an **illustrative set** for a 128 GB
box in this fleet shape. The production values are deliberately not
published — they encode the fleet's capacity plan. Size yours with the
logic below.

| Unit (generic) | Role | MemoryLow | MemoryMax | Notes |
|---|---|---|---|---|
| `llama-large-cpu.service` | 20B-class model, CPU-only inference (`-ngl 0`) | **6G** | 20G | Largest single low watermark: CPU inference holds the whole model + KV in anonymous RAM, all of it evictable without protection. |
| `llama-large.service` | large GPU-resident model | **4G** | 12G | |
| `llama-26b.service` | 26B GPU-resident model (the one from the case study) | **4G** | 14G | |
| `llama-8b.service` | mid-size GPU model | **3G** | 8G | |
| `llama-small-*.service` (×3) | small/flash models, 1–4B class | **1G** each | varies | |

Sizing logic:

- **`MemoryLow` ≈ the model's non-negotiable resident set** — the pages
  that, if evicted, cause a load stall or a GPU eviction storm: model
  weights resident in RAM (CPU inference) or the pinned/upload staging
  region plus KV cache headroom (GPU inference). It is deliberately
  smaller than the model's peak RSS; `memory.low` is protection against
  *unjustified* reclaim, not a reservation.
- **`MemoryMax` ≈ peak RSS plus headroom** for context growth, then
  rounded. A model that legitimately needs more should get a bigger
  budget explicitly, not silently push the box into global reclaim.
- Sum of all `MemoryLow` values must leave headroom for the OS, page
  cache, and the GPU driver's own allocations. This example set totals
  **20 GB on 128 GB** (6+4+4+3+1+1+1) — conservative on purpose. `memory.low` that in aggregate
  exceeds what the box can honor degenerates to no protection at all.
- Small models get 1G mostly so that a flash model being pounded cannot
  be fully evicted into a reload loop.

A worked unit example (`llama-26b.service`):

```ini
[Service]
# ... ExecStart, Environment, etc. ...
MemoryMax=14G
MemoryLow=4G
```

For CPU-heavy or chatty services we also use `MemoryHigh` (soft
throttling limit — reclaim starts but no OOM) and `MemorySwapMax`
(cap how much the service may push to swap, so a runaway can't recreate
the 26 GB swap state from the case study):

```ini
MemoryHigh=14G
MemoryMax=20G
MemoryLow=6G
MemorySwapMax=4G
```

## Applying budgets without restarts

`MemoryMax`/`MemoryLow` are cgroup attributes, not process properties —
systemd applies changes to the unit's cgroup on `daemon-reload`, and
the running processes inherit the new limits **without a restart**.

Manual way:

```bash
sudo systemctl set-property llama-26b.service MemoryMax=14G MemoryLow=4G
```

This writes a drop-in under
`/etc/systemd/system.control/llama-26b.service.d/` and applies it
immediately. It survives reboots.

Scripted way (idempotent, validates the unit exists first):

```bash
sudo scripts/apply-cgroup-budget.sh llama-26b.service --max 14G --low 4G
sudo scripts/apply-cgroup-budget.sh llama-large-cpu.service --max 20G --low 6G --high 14G --swap-max 4G
```

Verify what is actually in effect:

```bash
systemctl show llama-26b.service -p MemoryMax -p MemoryLow
cat /sys/fs/cgroup/system.slice/llama-26b.service/memory.low
cat /sys/fs/cgroup/system.slice/llama-26b.service/memory.max
```

Watch reclaim pressure actually hitting (or missing) a service:

```bash
cat /sys/fs/cgroup/system.slice/llama-26b.service/memory.stat | grep -E 'low|high'
# the "low" counter = times reclaim breached the low watermark
```

If the `low` breach counter climbs steadily under normal load, your
budgets sum too high or the box is genuinely undersized — no cgroup
setting fixes that, only fewer models or more RAM.

## Boot-time fleet assertion

The remediation reboot in the case study surfaced two latent config
bugs that had nothing to do with memory: one service had no `enable`
symlink (so it silently didn't come back after boot), and one service
user's home directory wasn't traversable by that user (so the unit
failed instantly on start). Both were invisible while the box stayed
up for 12 days.

`scripts/fleet-state-assert.sh` checks both conditions for every fleet
unit and exits nonzero (loudly) on any failure. Wire it in as a oneshot
that runs after the fleet:

```ini
# /etc/systemd/system/fleet-state-assert.service
[Unit]
Description=Assert inference fleet units are enabled and runnable
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fleet-state-assert llama-large-cpu.service llama-large.service llama-26b.service llama-8b.service llama-small-a.service llama-small-b.service llama-small-c.service

[Install]
WantedBy=multi-user.target
```

```bash
sudo install -m 0755 scripts/fleet-state-assert.sh /usr/local/sbin/fleet-state-assert
sudo systemctl daemon-reload
sudo systemctl enable --now fleet-state-assert.service
systemctl status fleet-state-assert.service   # should be "SUCCESS"
```

[unverified — from build notes] The unit file above is a sanitized
template; adjust the unit list to your fleet.
