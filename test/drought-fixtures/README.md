# Drought-check fixture

`getoraclesigners-1000.json`: the output of `digibyte-cli getoraclesigners 1000` on the dgb-tools anchor node
(v9.26.5) captured 2026-09-09T23:34Z at chain height 24,183,636, with identity fields (names, pubkeys, endpoints)
removed. 584 bundles over 26 distinct epochs (604,565 to 604,590). Slots 14 and 15 do not appear in any bundle;
every other slot does. Used by both monitors' self-tests to exercise the drought check against real Core output:
a slot sighted at the newest epoch reads drought 0; an absent slot reads the lower bound (newest epoch minus the
window's oldest epoch plus one) on the first read; a persisted earlier sighting makes the drought exact.
