# Network-view roster fixtures

Shared by `linux/dgb-oracle-monitor.sh --netview-selftest` and `monitor/oracle-monitor.ps1 -NetViewSelfTest`.
`expected.json` maps each fixture to the validator verdict (`ok` / `bad`). A roster is `ok` only when it is an array whose
row count equals its unique-`oracle_id` count equals 35, and every row has an integer `oracle_id`, string `status`,
string `heartbeat_status`, and an explicitly present integer `last_update` (0 = the never-received sentinel; null or
missing is a schema failure, not a sentinel). Compatibility restriction to the current mainnet roster size, not proof of completeness.
