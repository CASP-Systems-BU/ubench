"""EntityResolver: raw telemetry identifiers -> canonical entity IDs.

Vendored from gnnid's `src/gnnid/resolve.py` (see flowlib/__init__.py for
why). Identical to gnnid's copy except `from_snapshot` (offline, reads
kubectl JSON dumps off disk) is replaced by `from_live_api` (online, calls
the k8s API directly) — everything downstream of snapshot acquisition
(`_ingest_object`, `resolve_ip`, `resolve_hubble_endpoint`, ...) is untouched
so the two stay resolution-identical given equivalent cluster state. Canonical
IDs:
    pod:<ns>/<name>      svc:<ns>/<name>      workload:<ns>/<kind>/<name>
    dns:<fqdn>           ext:<class>          kubeapi:cluster
"""
from __future__ import annotations

from .schema import DNSNAME, EXTERNAL, KUBEAPI, POD, SERVICE, Entity

KUBEAPI_ID = "kubeapi:cluster"


def _hashish(seg: str) -> bool:
    """A k8s pod-template-hash / ReplicaSet suffix: alnum (no uppercase),
    4-11 chars, containing at least one digit. The digit requirement
    distinguishes a real hash ('649c7444bc', 'mljz4', all-digit '5976767489')
    from a word segment ('client', 'catalog'). Note str.islower() is False for
    all-digit strings, so we compare against .lower() instead."""
    return (4 <= len(seg) <= 11 and seg.isalnum() and seg == seg.lower()
            and any(c.isdigit() for c in seg))


def strip_pod_hash(pod_name: str) -> str:
    """frontend-5976767489-mljz4 -> frontend (ReplicaSet + pod hash suffixes);
    cilium-abcd1 -> cilium (single DaemonSet-style hash); ubuntu-client kept
    (no hash segments)."""
    parts = pod_name.split("-")
    if len(parts) >= 3 and _hashish(parts[-1]) and _hashish(parts[-2]):
        return "-".join(parts[:-2])
    if len(parts) >= 2 and _hashish(parts[-1]):
        return "-".join(parts[:-1])
    return pod_name


def normalize_dns(name: str) -> str:
    return name.lower().rstrip(".")


class EntityResolver:
    def __init__(self, run_id: str):
        self.run_id = run_id
        self.entities: dict[str, Entity] = {}
        self.ip_to_pod: dict[str, str] = {}      # pod IP -> pod entity_id
        self.node_ips: dict[str, str] = {}       # node InternalIP -> node name
        self.svc_cluster_ips: dict[str, str] = {}  # clusterIP -> svc entity_id
        self._pod_owner: dict[str, str] = {}     # pod name -> owner (RS/STS/DS) name
        self._rs_owner: dict[str, str] = {}      # RS name -> Deployment name
        self._add(Entity(run_id, KUBEAPI_ID, KUBEAPI, name="kube-apiserver"))

    # ------------------------------------------------------------------ build
    @classmethod
    def from_live_api(cls, run_id: str, kube_client) -> "EntityResolver":
        """Build a resolver straight from the k8s API instead of a snapshot
        file. `kube_client` exposes `.core` (CoreV1Api) and `.apps`
        (AppsV1Api) plus `.sanitize_for_serialization()` (an
        `kubernetes.client.ApiClient` instance, or anything exposing the same
        three calls) — see flow_resolver.py for how it's constructed from a
        kubeconfig. Equivalent to gnnid's `from_snapshot()` with a single
        point-in-time snapshot (no objects_end.json merge, since there is no
        "end of run" on a continuous stream)."""
        r = cls(run_id)

        def _dicts(raw_items, kind: str) -> list[dict]:
            out = []
            for obj in raw_items:
                d = kube_client.sanitize_for_serialization(obj)
                d["kind"] = kind  # list items omit kind/apiVersion
                out.append(d)
            return out

        items = _dicts(kube_client.core.list_pod_for_all_namespaces().items, "Pod")
        items += _dicts(kube_client.core.list_service_for_all_namespaces().items, "Service")
        items += _dicts(kube_client.apps.list_replica_set_for_all_namespaces().items, "ReplicaSet")
        for node in _dicts(kube_client.core.list_node().items, "Node"):
            name = node["metadata"]["name"]
            for addr in node.get("status", {}).get("addresses", []):
                if addr.get("type") == "InternalIP":
                    r.node_ips[addr["address"]] = name
        # two passes: owners first (RS -> Deployment chain), then pods/services
        for it in items:
            kind = it.get("kind")
            meta = it.get("metadata", {})
            if kind == "ReplicaSet":
                for ref in meta.get("ownerReferences", []) or []:
                    if ref.get("kind") == "Deployment":
                        r._rs_owner[meta["name"]] = ref["name"]
        for it in items:
            r._ingest_object(it)
        return r

    def _ingest_object(self, it: dict) -> None:
        kind = it.get("kind")
        meta = it.get("metadata", {})
        ns, name = meta.get("namespace", ""), meta.get("name", "")
        if kind == "Pod":
            eid = f"pod:{ns}/{name}"
            owner = None
            for ref in meta.get("ownerReferences", []) or []:
                owner = self._rs_owner.get(ref.get("name", ""), ref.get("name"))
                break
            labels = meta.get("labels", {}) or {}
            # The app label before the owner chain: per-replica pinned
            # Deployments (ubench render_manifests.py) are named frontend-1,
            # frontend-2, ... but their pods all carry app=frontend — the role
            # is the service, not the replica slot.
            canonical = (labels.get("service.istio.io/canonical-name")
                         or labels.get("app")
                         or (owner and strip_pod_hash(owner))
                         or strip_pod_hash(name))
            spec, status = it.get("spec", {}), it.get("status", {})
            containers = [c.get("name") for c in spec.get("containers", [])]
            ent = Entity(
                self.run_id, eid, POD, name=name, namespace=ns,
                canonical_service=canonical, workload=owner,
                node_name=spec.get("nodeName"), pod_ip=status.get("podIP"),
                service_account=spec.get("serviceAccountName"),
                uid=meta.get("uid"), has_sidecar="istio-proxy" in containers)
            self._add(ent)
            if status.get("podIP"):
                self.ip_to_pod[status["podIP"]] = eid
        elif kind == "Service":
            eid = f"svc:{ns}/{name}"
            self._add(Entity(self.run_id, eid, SERVICE, name=name, namespace=ns,
                             canonical_service=name, uid=meta.get("uid")))
            cip = it.get("spec", {}).get("clusterIP")
            if cip and cip not in ("None", ""):
                self.svc_cluster_ips[cip] = eid

    def _add(self, ent: Entity) -> None:
        self.entities.setdefault(ent.entity_id, ent)

    # ---------------------------------------------------------------- resolve
    def resolve_ip(self, ip: str | None) -> tuple[str, str] | None:
        """IP -> (entity_id, entity_type). Pods first, then service ClusterIPs,
        then node IPs (host-network -> external class), else external."""
        if not ip:
            return None
        if ip in self.ip_to_pod:
            return self.ip_to_pod[ip], POD
        if ip in self.svc_cluster_ips:
            return self.svc_cluster_ips[ip], SERVICE
        if ip in self.node_ips:
            return self.ext_entity("host"), EXTERNAL
        return self.ext_entity("world"), EXTERNAL

    def pod_by_name(self, ns: str, name: str) -> str | None:
        eid = f"pod:{ns}/{name}"
        return eid if eid in self.entities else None

    def service_entity(self, ns: str, name: str) -> str:
        eid = f"svc:{ns}/{name}"
        if eid not in self.entities:
            self._add(Entity(self.run_id, eid, SERVICE, name=name, namespace=ns,
                             canonical_service=name))
        return eid

    def dns_entity(self, fqdn: str) -> str:
        fqdn = normalize_dns(fqdn)
        eid = f"dns:{fqdn}"
        if eid not in self.entities:
            self._add(Entity(self.run_id, eid, DNSNAME, name=fqdn))
        return eid

    def ext_entity(self, cls: str) -> str:
        eid = f"ext:{cls}"
        if eid not in self.entities:
            self._add(Entity(self.run_id, eid, EXTERNAL, name=cls))
        return eid

    def resolve_hubble_endpoint(self, ep: dict | None) -> tuple[str, str] | None:
        """Hubble flow endpoint dict -> (entity_id, entity_type)."""
        if not isinstance(ep, dict):
            return None
        pod, ns = ep.get("pod_name"), ep.get("namespace")
        if pod and ns:
            eid = self.pod_by_name(ns, pod)
            if eid:
                return eid, POD
            # pod not in snapshot (churned) -> register from the flow itself
            wls = ep.get("workloads") or []
            canonical = (wls[0].get("name") if wls and wls[0].get("name")
                         else strip_pod_hash(pod))
            eid = f"pod:{ns}/{pod}"
            self._add(Entity(self.run_id, eid, POD, name=pod, namespace=ns,
                             canonical_service=canonical))
            return eid, POD
        for lbl in ep.get("labels") or []:
            if lbl.startswith("reserved:"):
                cls = lbl.split(":", 1)[1]
                if cls in ("host", "remote-node", "kube-apiserver"):
                    return self.ext_entity(cls), EXTERNAL
                return self.ext_entity("world"), EXTERNAL
        return self.resolve_ip(ep.get("ip") or (ep.get("IP") or {}).get("source"))

    def entity_type(self, eid: str) -> str | None:
        e = self.entities.get(eid)
        return e.entity_type if e else None
