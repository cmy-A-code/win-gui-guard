# Optional: USB key (second factor)

Some environments want the guard to exist *only* while an authorised dongle is present.
The design used by the original deployment:

1. A removable drive holds `cbx-key.dat` (32 random bytes) and `key-fingerprint.json`.
2. The fingerprint file contains `fast` (SHA-256 of a domain-separated concatenation of
   a constant, the key bytes, and a 0x00 separator) and `serial` (the volume serial).
3. On **Fast** checks only the fingerprint hash is compared. On **Deep** checks the
   volume serial must also match, which makes a copied key file on a different drive fail.
4. Any missing / unreadable / malformed material means **not authorised** (fail-closed).

Wire it into `Get-GuardState` as an extra gate (return an extra code, e.g. 5) before
returns 0. Keep the fingerprint on the drive itself — a local copy can be replayed.

This is deliberately not shipped here: the exact threat model, key storage and
enrollment flow are deployment-specific. Treat this file as a sketch, not code.
