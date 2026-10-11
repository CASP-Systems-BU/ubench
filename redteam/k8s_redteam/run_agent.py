"""Entry point: register our use case, then hand off to hackingBuddyGPT's CLI.

hackingBuddyGPT discovers use cases from the `use_cases` registry, which is
populated by the `@use_case` decorator at import time. Importing our use-case
module below registers `K8sPostCompromise`; then wintermute's `main()` parses
argv (`K8sPostCompromise --pod ... --node0 ...`) and runs it.

    redteam-agent K8sPostCompromise --pod <pod> --node0 <control-host>
    # equivalently:
    python -m k8s_redteam.run_agent K8sPostCompromise --pod <pod> --node0 <control-host>
"""
from __future__ import annotations

def _make_rich_markup_safe() -> None:
    """hackingBuddyGPT logs tool output through rich with markup enabled; shell
    output containing bracketed text (e.g. '[/.well-known/openid-configuration/]')
    is parsed as rich console markup and raises MarkupError, killing the run.
    Force markup off for every console print/log so arbitrary tool output renders
    literally. Only affects this process; the JSONL run log is unaffected."""
    try:
        import rich.console

        for meth in ("print", "log"):
            orig = getattr(rich.console.Console, meth)

            def wrap(orig):
                def inner(self, *a, **k):
                    k.setdefault("markup", False)
                    return orig(self, *a, **k)
                return inner

            setattr(rich.console.Console, meth, wrap(orig))
    except Exception:
        pass


_make_rich_markup_safe()

# noqa: F401 — imported for its @use_case side effect (registers K8sPostCompromise).
import k8s_redteam.usecases.k8s_postcompromise  # noqa: F401
from hackingBuddyGPT.cli.wintermute import main


if __name__ == "__main__":
    main()
