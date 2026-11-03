#!/usr/bin/env python3
"""flow-resolver: consume raw Hubble flows off Kafka, resolve+parse them the
same way gnnid's offline `ingest` does, and produce the result to a second
topic — so `hubble-flows-resolved` mirrors gnnid's `events.parquet` output,
just continuously instead of after the fact.

Runs one instance per Kafka broker VM (started by ../kafka.sh as the
transient systemd unit `ubench-flow-resolver`, alongside `ubench-kafka`).
Topology is assumed mostly static for now: the k8s snapshot behind the
resolver is built once at startup from a live k8s API call (not a watch/
informer), and optionally refreshed on a long interval to catch pod churn —
see --refresh-interval-s. A full watch-based resolver is deliberately out of
scope for this pass.

Pipeline:
    hubble-flows (raw, untouched)
        -> [this process] json.loads -> flowlib.hubble.parse_flow_obj
        -> hubble-flows-resolved (Event, one JSON object per message)
    on every snapshot (re)build:
        -> hubble-entities (Entity, one JSON object per message, keyed by
           entity_id — a compacted topic so each entity's latest row wins)

Usage:
    flow_resolver.py --kafka-brokers host1:9092,host2:9092,host3:9092 \\
        --kubeconfig ~/.kube/resolver.conf

Env (fallback when the matching flag is omitted, so the systemd unit can be
started the same way kafka.sh starts ubench-kafka — with env vars baked into
the unit rather than a long command line):
    KAFKA_BROKERS, KAFKA_TOPIC (default hubble-flows),
    KAFKA_RESOLVED_TOPIC (default hubble-flows-resolved),
    KAFKA_ENTITIES_TOPIC (default hubble-entities),
    RESOLVER_KUBECONFIG, RESOLVER_REFRESH_INTERVAL_S (default 0 = disabled),
    RESOLVER_RUN_ID (default: this host's hostname)
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import os
import socket
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from flowlib.hubble import parse_flow_obj  # noqa: E402
from flowlib.resolve import EntityResolver  # noqa: E402

log = logging.getLogger("flow_resolver")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kafka-brokers", default=os.environ.get("KAFKA_BROKERS"),
                    help="comma-separated host:port list (required)")
    ap.add_argument("--in-topic", default=os.environ.get("KAFKA_TOPIC", "hubble-flows"))
    ap.add_argument("--out-topic",
                    default=os.environ.get("KAFKA_RESOLVED_TOPIC", "hubble-flows-resolved"))
    ap.add_argument("--entities-topic",
                    default=os.environ.get("KAFKA_ENTITIES_TOPIC", "hubble-entities"))
    ap.add_argument("--group-id", default=os.environ.get("RESOLVER_GROUP_ID", "flow-resolver"))
    ap.add_argument("--kubeconfig",
                    default=os.environ.get("RESOLVER_KUBECONFIG",
                                           str(Path.home() / ".kube" / "resolver.conf")),
                    help="read-only kubeconfig for the resolver's k8s API access "
                         "(see ../provision_resolver_rbac.sh)")
    ap.add_argument("--run-id", default=os.environ.get("RESOLVER_RUN_ID", socket.gethostname()))
    ap.add_argument("--refresh-interval-s", type=float,
                    default=float(os.environ.get("RESOLVER_REFRESH_INTERVAL_S", "0")),
                    help="re-poll the k8s API this often to catch pod churn; "
                         "0 (default) polls only once at startup")
    ap.add_argument("--keep-rule", dest="keep_rules", action="append",
                    default=list(filter(None, os.environ.get(
                        "RESOLVER_KEEP_RULES", "non_forwarded,syn_no_ack,udp_first").split(","))),
                    help="L4 selection rule(s) to keep; repeatable "
                         "(default: non_forwarded,syn_no_ack,udp_first)")
    args = ap.parse_args(argv)
    if not args.kafka_brokers:
        ap.error("--kafka-brokers (or $KAFKA_BROKERS) is required")
    return args


def build_kube_client(kubeconfig: str):
    """A thin object exposing .core/.apps/.sanitize_for_serialization, as
    `EntityResolver.from_live_api` expects. Only read access to
    pods/services/nodes/replicasets is needed (see provision_resolver_rbac.sh
    for the matching ClusterRole)."""
    from kubernetes import client, config  # local import: optional dependency

    config.load_kube_config(config_file=kubeconfig)
    api_client = client.ApiClient()

    class _KubeClient:
        core = client.CoreV1Api(api_client)
        apps = client.AppsV1Api(api_client)
        sanitize_for_serialization = staticmethod(api_client.sanitize_for_serialization)

    return _KubeClient()


class ResolverHolder:
    """Holds the current EntityResolver and swaps it atomically on refresh,
    so the consume loop never blocks on a lock mid-flow."""

    def __init__(self, run_id: str, kubeconfig: str, on_rebuild):
        self._run_id = run_id
        self._kubeconfig = kubeconfig
        self._on_rebuild = on_rebuild
        self._resolver: EntityResolver | None = None
        self.rebuild()

    @property
    def resolver(self) -> EntityResolver:
        return self._resolver

    def rebuild(self) -> None:
        kube_client = build_kube_client(self._kubeconfig)
        resolver = EntityResolver.from_live_api(self._run_id, kube_client)
        log.info("snapshot built: %d entities, %d pod IPs, %d service IPs",
                 len(resolver.entities), len(resolver.ip_to_pod), len(resolver.svc_cluster_ips))
        self._resolver = resolver  # single reference swap: readers see old or new, never partial
        self._on_rebuild(resolver)


def _run_refresh_loop(holder: ResolverHolder, interval_s: float, stop: threading.Event) -> None:
    while not stop.wait(interval_s):
        try:
            holder.rebuild()
        except Exception:
            log.exception("snapshot refresh failed; keeping the previous snapshot")


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = parse_args(argv)
    from confluent_kafka import Consumer, Producer  # local import: optional dependency

    producer = Producer({"bootstrap.servers": args.kafka_brokers,
                         "linger.ms": 20, "compression.codec": "lz4",
                         "queue.buffering.max.messages": 200_000})

    def publish_entities(resolver: EntityResolver) -> None:
        for ent in resolver.entities.values():
            producer.produce(args.entities_topic, key=ent.entity_id,
                             value=json.dumps(dataclasses.asdict(ent)))
        producer.flush(10)

    holder = ResolverHolder(args.run_id, args.kubeconfig, publish_entities)

    stop = threading.Event()
    refresh_thread = None
    if args.refresh_interval_s > 0:
        refresh_thread = threading.Thread(
            target=_run_refresh_loop, args=(holder, args.refresh_interval_s, stop), daemon=True)
        refresh_thread.start()

    consumer = Consumer({"bootstrap.servers": args.kafka_brokers,
                        "group.id": args.group_id, "auto.offset.reset": "latest",
                        "enable.auto.commit": True})
    consumer.subscribe([args.in_topic])
    log.info("consuming %s -> resolving -> %s (brokers=%s)",
             args.in_topic, args.out_topic, args.kafka_brokers)

    produced = dropped = errors = 0
    last_log = time.monotonic()
    try:
        while True:
            msg = consumer.poll(1.0)
            if msg is None:
                if time.monotonic() - last_log > 60:
                    log.info("produced=%d dropped=%d errors=%d", produced, dropped, errors)
                    last_log = time.monotonic()
                continue
            if msg.error():
                log.warning("consumer error: %s", msg.error())
                errors += 1
                continue
            try:
                obj = json.loads(msg.value())
            except json.JSONDecodeError:
                errors += 1
                continue
            event_id = f"{args.run_id}:{msg.topic()}:{msg.partition()}:{msg.offset()}"
            event = parse_flow_obj(obj, args.run_id, holder.resolver, args.keep_rules, event_id)
            if event is None:
                dropped += 1
                continue
            producer.produce(args.out_topic, key=event.src_id,
                             value=json.dumps(dataclasses.asdict(event)))
            produced += 1
            producer.poll(0)  # service delivery-report callbacks without blocking
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        if refresh_thread:
            refresh_thread.join(timeout=5)
        consumer.close()
        producer.flush(10)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
