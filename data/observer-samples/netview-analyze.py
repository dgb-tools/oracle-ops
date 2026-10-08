#!/usr/bin/env python3
"""Replay the kit's network-view predicate variants over a raw observer series.
Input: JSONL lines {"t": epoch_seconds, "rows": [...]} (60 s series) or {"t":..., "roster": [...]} (30 s series).
For every 5-minute phase (reads at t0+phase, t0+phase+300, ...) and every slot, the longest run of consecutive
"miss" reads under each rule, and how many times each rule would have FIRED on a slot whose heartbeat was fresh on
every read (a healthy slot by the observer's own account). Rules:
  approved : miss = fresh heartbeat AND (last_update == 0 OR age > 3600); fire on the 3rd+ consecutive miss >= 900 s
             after the first (the rule on review/netview).
  gated-reset-X : as approved, but a miss counts only if the roster's zeroed fraction on that read is < X; a read that
             fails the gate RESETS the run.
  gated-pause-X : same gate; a gate-failing read neither counts nor resets (pause).
A persistently zeroed slot with a fresh heartbeat is simulated ("synthetic silent slot") to measure time-to-fire
under each rule, i.e. how often three gate-passing reads in a row occur.
"""
import json, sys, statistics as st, collections
path = sys.argv[1]; cadence = int(sys.argv[2]) if len(sys.argv) > 2 else 300
reads = []
for line in open(path):
    line = line.strip()
    if not line: continue
    o = json.loads(line); r = o.get("rows") or o.get("roster")
    if r: reads.append((int(o["t"]), r))
reads.sort()
t0 = reads[0][0]; span = reads[-1][0] - t0
step = reads[1][0] - reads[0][0] if len(reads) > 1 else 60
print(f"series: {len(reads)} reads, {span/60:.1f} min, native step ~{step}s, cadence replayed {cadence}s")
def zeroed_frac(r): return sum(1 for x in r if x.get("last_update") == 0) / len(r)
def slot_row(r, i):
    for x in r:
        if x["oracle_id"] == i: return x
    return None
rules = ["approved"] + [f"gated-{m}-{x}" for m in ("reset", "pause") for x in (0.5, 0.6, 0.7)]
def replay(seq, rule):
    """seq: list of (t, hb_fresh, zeroed, aged, roster_zf). Returns (fires, longest_run)."""
    streak = 0; since = None; fires = 0; longest = 0
    for t, fresh, zeroed, aged, zf in seq:
        miss = fresh and (zeroed or aged)
        if rule == "approved":
            if miss:
                if streak == 0: since = t
                streak += 1
            else: streak = 0
        else:
            _, mode, x = rule.split("-"); x = float(x)
            if miss and zf < x:
                if streak == 0: since = t
                streak += 1
            elif miss and zf >= x:
                if mode == "reset": streak = 0
                # pause: unchanged
            else: streak = 0
        longest = max(longest, streak)
        if streak >= 3 and since is not None and (t - since) >= 900: fires += 1; streak = 0; since = None  # count one fire per episode
    return fires, longest
phases = list(range(0, cadence, step))
results = collections.defaultdict(lambda: collections.defaultdict(list))  # rule -> slot -> [(phase, fires, longest)]
synthetic = collections.defaultdict(list)  # rule -> time to first fire (s) per phase, or None
healthy_slots = set()
for ph in phases:
    sel = [(t, r) for t, r in reads if (t - t0 - ph) % cadence < step and t - t0 >= ph]
    if len(sel) < 4: continue
    for i in range(35):
        seq = []; fresh_all = True
        for t, r in sel:
            x = slot_row(r, i)
            if x is None: fresh_all = False; break
            fresh = x.get("heartbeat_status") == "fresh"; fresh_all &= fresh
            lu = x.get("last_update") or 0
            seq.append((t, fresh, lu == 0, lu > 0 and (t - lu) > 3600, zeroed_frac(r)))
        if not fresh_all: continue
        healthy_slots.add(i)
        for rule in rules:
            f, L = replay(seq, rule); results[rule][i].append((ph, f, L))
    # synthetic always-zeroed fresh slot: time to first fire
    for rule in rules:
        seq = [(t, True, True, False, zeroed_frac(r)) for t, r in sel]
        streak = 0; since = None; tf = None
        for t, fresh, zeroed, aged, zf in seq:
            ok = True
            if rule != "approved":
                _, mode, x = rule.split("-"); x = float(x)
                if zf >= x:
                    ok = False
                    if mode == "reset": streak = 0; since = None
            if ok:
                if streak == 0: since = t
                streak += 1
            if streak >= 3 and since is not None and (t - since) >= 900: tf = t - sel[0][0]; break
        synthetic[rule].append(tf)
print(f"slots with a fresh heartbeat on every read (healthy by the observer): {len(healthy_slots)} of 35")
print(f"{'rule':18s} {'fires/healthy-slot-phases':>26s} {'slots ever fired':>17s} {'longest run (max over slots)':>29s} {'synthetic silent slot: fired in':>32s} {'median time-to-fire':>20s}")
for rule in rules:
    fires = sum(f for i in results[rule] for _, f, _ in results[rule][i]); n = sum(len(results[rule][i]) for i in results[rule])
    fired_slots = sorted(i for i in results[rule] if any(f > 0 for _, f, _ in results[rule][i]))
    longest = max((L for i in results[rule] for _, _, L in results[rule][i]), default=0)
    tfs = [x for x in synthetic[rule] if x is not None]
    print(f"{rule:18s} {fires:>10d} / {n:<13d} {str(fired_slots):>17s} {longest:>29d} {len(tfs):>14d} / {len(synthetic[rule]):<15d} {(str(int(st.median(tfs)/60))+' min') if tfs else 'never':>20s}")
zf = [zeroed_frac(r) for _, r in reads]
print(f"roster zeroed fraction per read: min {min(zf):.2f} p25 {sorted(zf)[len(zf)//4]:.2f} median {st.median(zf):.2f} p75 {sorted(zf)[3*len(zf)//4]:.2f} max {max(zf):.2f}; reads with zf >= 0.5: {sum(1 for v in zf if v>=0.5)}/{len(zf)}")
aged = [sum(1 for x in r if (x.get('last_update') or 0) > 0 and t - x['last_update'] > 3600) for t, r in reads]
print(f"aged (>3600 s, last_update>0) count per read: max {max(aged)}")
