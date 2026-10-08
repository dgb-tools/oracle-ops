#!/usr/bin/env python3
"""Signing-gap statistics from the participation ledger, as used to size the drought check (2026-10-08).

Input: the oracle-ledger's data/blocks.jsonl (one JSON object per block with oracle_present, valid, epoch, slots).
Definitions:
  bundle epoch   an epoch (height // 40) in which at least one valid oracle bundle was included in a block
  signer set     the union of the `slots` of all valid bundles in that epoch (the ledger shows exactly 7 per epoch)
  gap            for one slot, the number of bundle epochs from one appearance to the next (counted in bundle
                 epochs, i.e. the clock the monitor uses; epochs with no bundle at all do not advance it)
  healthy slot   signing rate (appearances / bundle epochs) >= 0.21, which is 7/35 with the slots that had long
                 outages excluded; the excluded slots and their rates are printed
Outputs: the gap distribution for healthy slots, the fraction of gaps >= K for several K against the geometric
model P(gap >= K) = 0.8^(K-1) (independent, equal-probability selection), every healthy gap >= 36 with dates
(outage labels are read off the dates by hand; see data/drought/ledger-gaps-2026-10-08.md), and the longest
bundle-less stretches. Usage: drought-gaps.py /path/to/blocks.jsonl
"""
import json, sys, collections, time, statistics as st
path = sys.argv[1]
ep_signers = collections.defaultdict(set); ep_time = {}; nblocks = 0; hmin = hmax = None; invalid = 0
for line in open(path):
    o = json.loads(line); nblocks += 1; h = o["height"]
    hmin = h if hmin is None else min(hmin, h); hmax = h if hmax is None else max(hmax, h)
    if not o.get("oracle_present"): continue
    if o.get("valid") is False: invalid += 1; continue
    if o.get("epoch") is None: continue
    ep_signers[o["epoch"]].update(o.get("slots") or []); ep_time.setdefault(o["epoch"], o["time"])
epochs = sorted(ep_signers); idx = {e: i for i, e in enumerate(epochs)}
d = lambda e: time.strftime('%Y-%m-%d %H:%MZ', time.gmtime(ep_time[e]))
print(f"blocks {nblocks} ({hmin}..{hmax}); raw epochs {hmax//40 - hmin//40 + 1}; bundle epochs {len(epochs)}; invalid bundles skipped {invalid}")
print("signers per bundle epoch:", dict(sorted(collections.Counter(len(ep_signers[e]) for e in epochs).items())))
rate = {s: sum(1 for e in epochs if s in ep_signers[e]) / len(epochs) for s in range(35)}
healthy = [s for s in range(35) if rate[s] >= 0.21]
print("per-slot signing rate:", " ".join(f"{s}:{rate[s]:.2f}" for s in range(35)))
print(f"healthy (rate >= 0.21): {healthy}; excluded: {[(s, round(rate[s], 2)) for s in range(35) if s not in healthy]}")
gaps = collections.defaultdict(list)
for s in range(35):
    signed = [e for e in epochs if s in ep_signers[e]]
    for a, b in zip(signed, signed[1:]): gaps[s].append((idx[b] - idx[a], a, b))
hg = [g for s in healthy for g, _, _ in gaps[s]]
print(f"healthy gaps: n={len(hg)} median {st.median(hg)} p90 {sorted(hg)[int(len(hg)*0.9)]} p99 {sorted(hg)[int(len(hg)*0.99)]} max {max(hg)}")
for K in (18, 24, 30, 36, 48, 60):
    n = sum(1 for g in hg if g >= K); print(f"  gaps >= {K:2d} ({K/6:4.1f} h at one epoch per 10 min): observed {100*n/len(hg):.3f}% ({n}), geometric model {100*0.8**(K-1):.3f}%")
print("healthy gaps >= 36 (label by date):")
for s in healthy:
    for g, a, b in gaps[s]:
        if g >= 36: print(f"  slot {s:2d}: {g:4d} bundle epochs  {d(a)} -> {d(b)}")
raw = sorted(ep_time); stretches = sorted(((raw[i+1] - raw[i] - 1, raw[i]) for i in range(len(raw)-1) if raw[i+1] - raw[i] > 1), reverse=True)
print("longest bundle-less stretches (raw epochs, after):", [(g, d(e)) for g, e in stretches[:6]])
