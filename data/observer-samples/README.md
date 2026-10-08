# Observer samples

Raw reads of `https://digibyte.io/api/getoracles`, one JSON line per read, kept so anyone can
recompute the network-view predicate at any threshold, cadence or gate.

- `2026-10-08/netview-sample-60s.jsonl`: `{"t","http","sha","rows":[...]}` every 60 s from
  13:07Z, taken from the dgb-tools workstation; `rows` keeps `oracle_id`, `status`,
  `heartbeat_status`, `last_update`, `price_source`, `selected_for_epoch`, `in_consensus`,
  `is_active`, `heartbeat_timestamp`, `heartbeat_age_seconds`, `heartbeat_signature_valid`,
  `last_price_micro_usd`, `software_version`, `client_version`. Identity fields (name, pubkey,
  endpoint) are not kept. The file is replaced by the full 3-hour series when that completes.
- `2026-10-08/netview-split-sample-30s.jsonl`: `{"t","roster":[full rows as served]}` every 30 s,
  13:01 to 13:16Z, taken on the slot-29 oracle box.
- `netview-analyze.py <file> [cadence_seconds]`: replays the predicate variants over a series at
  a chosen cadence across every phase: the rule as approved on 2026-10-07 (explicit 0 or aged =
  miss), and roster-fraction gates at 0.5/0.6/0.7 with reset or pause semantics. It reports fires
  per healthy slot-phase (a slot is "healthy" when its heartbeat is fresh on every read), the
  longest miss run, and time-to-fire for a synthetic always-zeroed slot. A fire is counted once
  per episode (the streak is reset after a fire), so the numbers are alert incidents, not
  repeated evaluations. Windows are measured by read count at the chosen cadence; three reads
  five minutes apart span ten minutes, and the 900-second elapsed gate is applied on timestamps.
