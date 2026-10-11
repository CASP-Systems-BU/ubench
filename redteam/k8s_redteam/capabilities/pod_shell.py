"""A hackingBuddyGPT capability that runs shell commands inside a compromised pod.

This is how we "expose kubectl to the agent" (the plan's in-cluster vantage): the
LLM is told it has a shell on a foothold pod; each tool call is transparently run
as `kubectl exec` in that pod, reached by SSHing to the control node (which holds
the admin kubeconfig). The agent never deals with the exec plumbing — from its
point of view it simply has a post-compromise shell, and `kubectl` inside the pod
is authenticated as the pod's mounted service account.

Mirrors the shape of hackingBuddyGPT's own SSHRunCommand capability
(`async __call__(self, command: str) -> str`); the single typed parameter becomes
the function-calling tool schema automatically (see Capability.to_model).
"""
import shlex
import subprocess
from dataclasses import dataclass
from typing import override

from hackingBuddyGPT.capability import Capability


@dataclass
class PodShellCapability(Capability):
    pod: str
    node0: str
    node0_user: str = "yuhang"
    namespace: str = "redteam"
    container: str = "agent"
    timeout: int = 60
    max_output: int = 8000

    @override
    def get_name(self) -> str:
        # Tool name offered to the LLM (keyed in the capability registry).
        return "run_shell_command"

    @override
    def describe(self) -> str:
        return (
            "Run a single shell command inside the compromised pod you have a foothold on. "
            "Each call runs in a fresh `sh -lc` shell, so state (cwd, environment, shell "
            "variables) is NOT preserved between calls — chain steps with '&&' or ';' within one "
            "command when they must share state. `kubectl` is installed and already authenticated "
            "as the pod's mounted service account, so you can run e.g. "
            "`kubectl auth can-i --list`, `kubectl get pods -A`, `kubectl get secrets -A`. "
            "Common tools (curl, jq, nslookup/dig, cat, ls, env) are available. "
            "Returns the combined stdout+stderr and the exit code."
        )

    @override
    async def __call__(self, command: str) -> str:
        # Build the remote command as ONE shell-quoted string so neither the control
        # node's login shell nor `sh -lc` in the pod re-splits a multi-word command.
        remote = "kubectl exec -n {ns} -c {c} {pod} -- sh -lc {cmd}".format(
            ns=shlex.quote(self.namespace),
            c=shlex.quote(self.container),
            pod=shlex.quote(self.pod),
            cmd=shlex.quote(command),
        )
        argv = [
            "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15", f"{self.node0_user}@{self.node0}", remote,
        ]
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return f"(command timed out after {self.timeout}s)"
        except Exception as e:  # pragma: no cover - surfaced to the LLM as tool output
            return f"(local error running kubectl exec: {e})"

        out = ((p.stdout or "") + (p.stderr or "")).strip()
        if len(out) > self.max_output:
            out = out[: self.max_output] + f"\n(...truncated, {len(out)} bytes total)"
        return f"(exit={p.returncode})\n{out}" if out else f"(exit={p.returncode}, no output)"
