# Ledger packet for the signing-drought check (2026-10-08)

What the numbers in the monitors and the runbook rest on, so they can be recomputed or disputed.
Output of `scripts/drought-gaps.py` over the oracle-ledger's `data/blocks.jsonl` is in
`ledger-gaps-2026-10-08.txt` beside this file.

## Source

The participation ledger (github.com/dgb-tools/oracle-ledger), `data/blocks.jsonl`: 440,853 mainnet
blocks, heights 23,869,440 to 24,310,292 (2026-07-18 to 2026-10-01), walked from explorer raw
blocks with the hash chain checked, each block's coinbase scanned for the oracle bundle and the
participation bitmap decoded with the same rules Core uses (`test/core-crosscheck.test.js` in the
ledger reproduces Core's `signer_ids` for every bundle of a 1000-block `getoraclesigners` sample).

## Definitions

- **Epoch**: height // 40. **Bundle epoch**: an epoch with at least one valid bundle in a block.
  Raw epochs in the span: 11,022. Bundle epochs: 10,476 (544 raw epochs carried no bundle; the
  longest bundle-less stretch was 5 epochs). No invalid bundle was present.
- **Signer set of an epoch**: the union of the signer slots of that epoch's bundles. Every one of
  the 10,476 bundle epochs has exactly 7 signers, so bundles within an epoch repeat one signing.
- **Gap**: for one slot, the number of bundle epochs from one epoch in which it signed to the next
  epoch in which it signed. The clock is bundle epochs, which is the clock the monitor uses; epochs
  with no bundle do not advance it. Raw-epoch gaps are a little longer (about 5 percent).
- **Signing rate**: a slot's signed epochs divided by all bundle epochs.
- **Healthy slot (eligibility)**: rate >= 0.21. With 7 of 35 chosen per epoch a slot that never
  missed would sign 0.20 of epochs if every slot were eligible every epoch; slots that were absent
  for long stretches raise the others' rate slightly, and the 22 slots at or above 0.21 sit at
  0.21 to 0.23 (slots 0, 2, 6, 7, 8, 9, 10, 12, 16, 17, 18, 19, 20, 21, 22, 25, 26, 28, 29, 31,
  33, 34). The 13 excluded slots and their rates: 1 (0.13), 3 (0.21 rounded, below the cut),
  4 (0.18), 5 (0.20), 11 (0.17), 13 (0.13), 14 (0.16), 15 (0.11), 23 (0.21 rounded, below the
  cut), 24 (0.12), 27 (0.11), 30 (0.14), 32 (0.17). Slots 3, 4, 5 and 23 were excluded by the
  threshold, not by an outage label; including them changes the tail counts by a handful.

## Results (22 healthy slots, 51,806 gaps)

- median gap 3 bundle epochs; 90th percentile 9; 99th percentile 19; maximum 390.
- Fraction of gaps at or above K, observed against the model P(gap >= K) = 0.8^(K-1), which is
  independent, equal-probability selection of 7 of 35 each epoch:

| K (epochs) | hours at 1 epoch/10 min | observed | model | count |
|---|---|---|---|---|
| 18 | 3 | 1.315% | 2.252% | 681 |
| 24 | 4 | 0.322% | 0.590% | 167 |
| 30 | 5 | 0.129% | 0.155% | 67 |
| 36 | 6 | 0.073% | 0.041% | 38 |
| 48 | 8 | 0.039% | 0.003% | 20 |
| 60 | 10 | 0.035% | 0.000% | 18 |

Below 30 the observed tail is lighter than the model (healthy slots are slightly more likely to be
chosen than 1 in 5 because some slots are absent). At 36 to 47 the observed count (18) is close to
what the model expects for a lottery tail (about 20 of 51,806). At 48 and above, 20 gaps are
observed where the model expects 1.5, so that band is outages, not lottery.

## The 38 healthy gaps of 36 or more, labeled by date

- **Aug 27 network-wide crash** (the runbook's "August 2026 crash"; onsets 02:30 to 04:29Z):
  slots 0 (70), 25 (227), 28 (65), 29 (62), 34 (90). Five gaps.
- **One operator, two slots dark together** (slots 7 and 20 with identical windows): Aug 6
  (73, 69), Aug 14 (85, 85), Sep 10 to 11 (39, 36), Sep 19 to 20 (42, 39). Eight gaps.
- **Multi-day single-slot outages**: slot 8 Aug 20 to 22 (266), slot 21 Aug 11 to 14 (390),
  slot 31 Jul 22 to 25 (327) with its neighbors 67 and 48 on Jul 22 and Jul 27. Five gaps.
- **Jul 18, two slots from 05:15Z** (slots 10 (89) and 29 (39)): shared onset, cause not recorded.
  Two gaps.
- **Single-slot gaps of 48 or more without a recorded event** (by the model these are outages,
  P < 3 in 100,000 each): slot 12 Sep 29 to 30 (73), slot 16 Aug 19 (53), slot 21 Sep 15 (98),
  slot 34 Jul 29 (77) and Sep 11 (79). Five gaps.
- **Single-slot gaps of 36 to 47 without a recorded event** (consistent with the lottery tail):
  slot 0 Jul 28 (37), slot 8 Sep 26 (39), slot 9 Aug 1 (38), slot 12 Aug 7 (40), slot 17 Aug 19
  (37), slot 18 Aug 21 (36), slot 21 Jul 24 (38) and Jul 27 (38), slot 22 Aug 23 (39), slot 25
  Jul 30 (36), slot 28 Jul 31 (40) and Sep 5 (39), slot 33 Aug 20 (44). Thirteen gaps.

So of the 38, 25 are attributable to dated or paired events or are too long for the lottery, and
13 are single-slot 36 to 47 gaps that the lottery model would produce at about this rate.

## What this does and does not establish

- A threshold of 36 bundle epochs pages a healthy slot about as often as the lottery tail
  predicts: 0.041% of gaps under the model, 0.073% observed including unlabeled gaps. At about
  29 signings per slot per day, the model is one false page per slot per 85 days; the observed
  rate including the 13 unlabeled gaps is about one per 48 days. Both are provisional: the model's
  independence assumption is supported by the rates, not proven, and 75 days of one network's
  history is the whole sample.
- A drought is **absent participation on this node's chain**, not proof of a silent price path.
  The one silent-price case in the sample (slot 29, Oct 1 to 6) shows as a drought for its whole
  duration, which is one case.
- Counts here are gap **incidents** (one per gap). The monitor fires once per episode and
  re-sends an unresolved alert every `realert_hours`; those re-sends are not incidents.
- Slot 29's own gaps at or above 24 in the sample: ten, the longest 62 (the Aug 27 crash) and 39
  (Jul 18), the rest 25 to 29 bundle epochs. None above 36 outside the two dated events.
