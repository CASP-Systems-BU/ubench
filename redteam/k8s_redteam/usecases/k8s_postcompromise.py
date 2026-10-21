"""hackingBuddyGPT use case: autonomous post-compromise K8s assessment from a pod.

Tool-calling agent (native function calling, real chat history) modeled on the
upstream MinimalToolCallPrivEscLinux. It drives a foothold pod through the
`run_shell_command` capability (kubectl exec into the pod) and records findings,
so the resulting cluster telemetry contains a realistic, autonomously-generated
post-compromise attack trace to label and detect.

Run via the `redteam-agent` console script or `python -m k8s_redteam.run_agent`:

    redteam-agent K8sPostCompromise --pod <pod> --node0 <control-host> \
        --node0_user <ssh-user> --namespace redteam

LLM/limits come from the .env (OpenRouter by default); see redteam/.env.example.
"""
# NOTE: no `from __future__ import annotations` — hackingBuddyGPT's @configurable
# introspection reads raw field type annotations, so they must be real types
# (e.g. `llm: LiteLLM`), not PEP 563 strings.
from typing import override

from hackingBuddyGPT.capabilities.record_note import RecordNote
from hackingBuddyGPT.capability import function_call_capability
from hackingBuddyGPT.usecases.agents import ChatAgent
from hackingBuddyGPT.usecases.usecase import AutonomousAgentUseCase, use_case
from hackingBuddyGPT.utils.configurable import parameter
from hackingBuddyGPT.utils.limits import Limits
from hackingBuddyGPT.utils.llm import LiteLLM

from k8s_redteam.capabilities.pod_shell import PodShellCapability


class K8sPostCompromiseAgent(ChatAgent):
    llm: LiteLLM  # pin the litellm-based upstream, matching ChatAgent

    pod: str = parameter(desc="name of the compromised pod to operate from", default="")
    node0: str = parameter(
        desc="control-node host that can `kubectl exec` into the pod (e.g. apt097.apt.emulab.net)",
        default="",
    )
    node0_user: str = parameter(desc="ssh user on the control node", default="")
    namespace: str = parameter(desc="namespace of the compromised pod", default="redteam")
    container: str = parameter(desc="container name inside the pod", default="agent")
    cmd_timeout: int = parameter(desc="per-command timeout in seconds", default=60)
    goal: str = parameter(
        desc="optional specific objective appended to the system prompt (e.g. 'change the root "
        "password of the victim-host pod'); blank = generic recon + escalation",
        default="",
    )

    @override
    async def system_message(self, limits: Limits) -> str:
        msg = (
            "You are an autonomous Kubernetes security-assessment agent. As part of an AUTHORIZED "
            "red-team exercise on a dedicated research cluster, you have obtained a foothold: shell "
            f"access on a single compromised pod in namespace '{self.namespace}'. The pod has a "
            "service-account token mounted and `kubectl` available, already authenticated as that "
            "service account.\n\n"
            "Your objective is to assess what this foothold exposes, by enumerating your access and "
            "the surrounding cluster and attempting realistic lateral movement and privilege "
            "escalation. Proceed methodically:\n"
            "1. Establish identity and permissions: `id`, inspect the mounted token path, "
            "`kubectl auth can-i --list`.\n"
            "2. Enumerate the cluster you can see: namespaces, pods, services, nodes, deployments, "
            "endpoints.\n"
            "3. Look for reachable services and credentials: service endpoints you can curl, "
            "configmaps, secrets (some attempts will be denied — note which).\n"
            "4. Attempt lateral movement toward other workloads and toward higher privilege, and "
            "record what succeeds versus what is forbidden.\n\n"
            "Tools available to you:\n"
            "- 'run_shell_command' runs ONE shell command inside the compromised pod. The shell is "
            "fresh each call, so chain steps with '&&' when they must share state. Use it for both "
            "local recon and `kubectl`.\n"
            "- 'record_note' records a finding you want to keep (accessible resources, credentials, "
            "reachable targets, successful vs denied actions).\n"
            "- 'conclude' ends the run; call it with a short summary once you have mapped your "
            "access or exhausted useful actions.\n\n"
            "Work autonomously and step by step; nobody will answer questions. Do not repeat actions "
            "that already failed. Keep going until you have characterized the exposure of this "
            "foothold."
        )
        if self.goal:
            msg += (
                "\n\nSPECIFIC OBJECTIVE FOR THIS ENGAGEMENT — pursue this concretely, in addition to "
                "the recon above and using whatever access you discover:\n"
                f"{self.goal}\n"
                "Report whether you achieved it and the exact commands that worked."
            )
        return msg

    @override
    async def before_run(self, limits: Limits):
        if not self.pod or not self.node0:
            raise ValueError(
                "K8sPostCompromise requires --pod and --node0 (the foothold pod and the control "
                "node that can kubectl-exec into it)."
            )
        await super().before_run(limits)

        async def conclude(summary: str) -> str:
            """End the assessment run, recording a short summary of findings."""
            limits.complete()
            return f"Assessment concluded. Summary recorded: {summary}"

        self.add_capability(
            PodShellCapability(
                pod=self.pod,
                node0=self.node0,
                node0_user=self.node0_user,
                namespace=self.namespace,
                container=self.container,
                timeout=self.cmd_timeout,
            ),
            default=True,
        )
        self.add_capability(RecordNote())
        self.add_capability(
            function_call_capability(
                conclude,
                description=(
                    "Call this when you have finished the assessment or run out of useful actions. "
                    "The 'summary' argument should briefly state what access the foothold exposed "
                    "and what you were able to reach. This ends the run."
                ),
                name="conclude",
            )
        )


@use_case("Post-compromise Kubernetes recon & lateral-movement from a foothold pod")
class K8sPostCompromiseUseCase(AutonomousAgentUseCase[K8sPostCompromiseAgent]):
    pass
