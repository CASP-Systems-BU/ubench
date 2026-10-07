# Tetragon TracingPolicy scaffold

Each file here is one independent `TracingPolicy` CRD, applied/removed with
`../tetra_policy.sh` against the live cluster — no agent restart, no effect
on the others. This is the "pick a syscall, measure the overhead, swap it
out" workflow: enable one, run an experiment, disable it, enable a different
one, compare.

| File | Hooks | Tactic relevance |
|---|---|---|
| `execve.yaml` | `sys_execve` | Raw syscall-level exec timing (Tetragon already emits a higher-level `process_exec` event by default, no policy needed — this is for when you want the syscall ABI's own entry/return instead) |
| `openat.yaml` | `sys_openat` (unfiltered) | Catches `k8s.credential-access.steal-serviceaccount-token`'s read of `/var/run/secrets/kubernetes.io/serviceaccount/token`, and any Secret-mount access generally. Broadest/noisiest policy here — narrow it with a `selectors.matchArgs` path filter once you've measured unfiltered overhead |
| `connect.yaml` | `tcp_connect`/`tcp_close`/`tcp_sendmsg` | The one that matters for techniques crossing the control-plane → worker-node network boundary (`nodes-proxy`'s kubelet-proxy hop, `steal-serviceaccount-token`'s `kubectl exec` stream) — see the main README's "Kubernetes attack simulation" section |
| `ptrace.yaml` | `sys_ptrace` | Credential-access / container-breakout primitive; not exercised by any Stratus technique tested so far |
| `setuid.yaml` | `sys_setuid` | Privilege escalation signal *inside* a process — what happens after a `privileged-pod`/`hostpath-volume` breakout, invisible to the k8s audit log (control-plane API calls only) |

## Usage

```bash
./tetra_policy.sh list                # show available + currently-applied policies
./tetra_policy.sh enable  openat       # apply one policy
./tetra_policy.sh disable openat       # remove it
./tetra_policy.sh enable  all          # apply every policy in this directory
```

## Adding a new one

Copy the shape of an existing file, give `metadata.name` a unique
`syscall-<thing>` name (so multiple scaffold policies can be applied
simultaneously without colliding), and drop it in this directory —
`tetra_policy.sh` picks up any `*.yaml` here automatically. Real upstream
examples with `matchArgs`/`matchActions` selectors (narrowing to specific
paths, UIDs, enforcing instead of just observing) live at
[cilium/tetragon/examples/tracingpolicy](https://github.com/cilium/tetragon/tree/main/examples/tracingpolicy).
