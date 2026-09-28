# Contributing

This project is young and security-critical. The contributions worth the most right now:

1. **Leak reports.** Any path by which qube data reaches the internal disk, any
   log that records a sensitive qube name, any way the volume passphrase could
   reach dom0. Open an issue with exact reproduction steps — these are treated
   as the highest-priority bugs.
2. **Adversarial review of the threat model** in the README. Tell us where the
   stated guarantees are weaker than claimed.
3. **Portability reports.** The scripts target Qubes OS 4.3; reports (and
   patches) for other supported releases are welcome.

Ground rules for patches:

- Keep the invariants: fail closed; media detached only after a proven
  dismount; placement of every volume verified; passphrase never in dom0.
- Every command a reviewer might question gets a comment explaining why it is
  there. Transparency over brevity.
- No hardware-specific assumptions in the shared layer.
- One logical change per PR, with the "why" in the commit message.

By contributing you agree your work is released under the MIT license.
