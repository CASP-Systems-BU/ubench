# redteam launchpad placement

One attacker pod, deployed outside the benchmark render pipeline (applied directly
by `scripts/cloudlab/redteam.sh`, not `render_manifests.py`).

| object | where | why |
|---|---|---|
| namespace `redteam` | — | ground-truth label boundary (never benign) |
| Deployment `redteam-agent` | `nodeSelector ubench.io/node-index: "2"` | co-located with boutique backends (cart/checkout/currency) so east-west activity makes real flows |
| SA `redteam-agent` | ns `redteam` | audit identity `system:serviceaccount:redteam:redteam-agent` |

RBAC profile is chosen at apply time: `rbac-recon.yaml` (default, read-only
misconfig) or `rbac-escalated.yaml` (write/exec/secret-theft succeeds). Both bind
only this one SA, so the attacker identity stays exact for labeling.

Labels stamped on every object: `ubench.io/role: attacker`.
