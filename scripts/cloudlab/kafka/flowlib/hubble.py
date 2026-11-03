"""Hubble flow (one jsonpb object) -> L4_FLOW / DNS_QUERY Event.

Vendored from gnnid's `src/gnnid/ingest/hubble.py` (see flowlib/__init__.py).
Only `parse_flow_obj` is kept here — the per-object function gnnid's file
loop (`parse_flows`) calls per line; the streaming consumer calls it per
Kafka message instead, so both paths resolve identically.

Hubble emits many observations per connection; the L4 selection rule keeps
only informative ones:
  * verdict != FORWARDED           (drops/denials — always keep)
  * TCP SYN without ACK            (connection open)
  * UDP/ICMP with is_reply=false   (first packet of an exchange)
DNS: one DNS_QUERY per l7.dns RESPONSE line (it carries the rcode; every
request gets a response, NXDOMAIN included). Streams without L7 DNS
visibility simply produce no DNS events.
"""
from __future__ import annotations

import datetime
import re

from .resolve import EntityResolver, normalize_dns
from .schema import DNS_QUERY, L4_FLOW, Event

_FRAC_RE = re.compile(r"\.(\d+)")


def _iso_epoch(ts: str | None) -> float | None:
    if not isinstance(ts, str):
        return None
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    # Hubble emits nanosecond-precision fractional seconds (9 digits).
    # datetime.fromisoformat only accepts arbitrary fractional-second length
    # on Python 3.11+; on 3.10 (the Kafka broker VMs' stock interpreter,
    # vs. gnnid's own >=3.12 requirement) it only accepts 0/3/6 digits and
    # raises on 9 — truncate to microseconds for portability across both.
    m = _FRAC_RE.search(ts)
    if m and len(m.group(1)) > 6:
        ts = ts[:m.start(1)] + m.group(1)[:6] + ts[m.end(1):]
    try:
        return datetime.datetime.fromisoformat(ts).timestamp()
    except ValueError:
        return None


def _l4(flow: dict) -> tuple[str | None, int | None, dict]:
    l4 = flow.get("l4") or {}
    for proto in ("TCP", "UDP", "ICMPv4", "ICMPv6"):
        if proto in l4:
            p = l4[proto] or {}
            name = "icmp" if proto.startswith("ICMP") else proto.lower()
            return name, p.get("destination_port"), p.get("flags") or {}
    return None, None, {}


def keep_l4(flow: dict, keep_rules: list[str]) -> bool:
    verdict = flow.get("verdict", "UNKNOWN")
    proto, _, flags = _l4(flow)
    if "non_forwarded" in keep_rules and verdict != "FORWARDED":
        return True
    if ("syn_no_ack" in keep_rules and proto == "tcp"
            and flags.get("SYN") and not flags.get("ACK")):
        return True
    if ("udp_first" in keep_rules and proto in ("udp", "icmp")
            and not flow.get("is_reply", False)):
        return True
    return False


def parse_flow_obj(obj: dict, run_id: str, resolver: EntityResolver,
                   keep_rules: list[str], event_id: str) -> Event | None:
    """One decoded Hubble jsonpb object -> Event, or None if dropped by the
    selection rule or missing required fields."""
    flow = obj.get("flow", obj)
    ts = _iso_epoch(flow.get("time"))
    if ts is None:
        return None
    dns = (flow.get("l7") or {}).get("dns") or {}

    if dns.get("query"):
        # DNS_QUERY: querier pod -> DNSName. RESPONSE carries the rcode and
        # the querier is the *destination* endpoint of the response flow.
        l7type = (flow.get("l7") or {}).get("type", "")
        if l7type != "RESPONSE":
            return None
        querier = resolver.resolve_hubble_endpoint(flow.get("destination"))
        if querier is None:
            return None
        fqdn = normalize_dns(dns["query"])
        return Event(
            event_id=event_id, run_id=run_id, ts=ts, event_type=DNS_QUERY,
            src_id=querier[0], src_type=querier[1],
            dst_id=resolver.dns_entity(fqdn), dst_type="DNSName",
            dns_query=fqdn,
            dns_qtypes=",".join(dns.get("qtypes") or []),
            dns_rcode=str(dns.get("rcode", "")) or None)

    if not keep_l4(flow, keep_rules):
        return None
    src = resolver.resolve_hubble_endpoint(flow.get("source"))
    dst = resolver.resolve_hubble_endpoint(flow.get("destination"))
    if src is None or dst is None:
        return None
    proto, dport, _ = _l4(flow)
    return Event(
        event_id=event_id, run_id=run_id, ts=ts, event_type=L4_FLOW,
        src_id=src[0], src_type=src[1], dst_id=dst[0], dst_type=dst[1],
        l4_proto=proto, dst_port=dport,
        verdict=flow.get("verdict", "UNKNOWN"),
        drop_reason=flow.get("drop_reason_desc"),
        is_reply=bool(flow.get("is_reply", False)))
