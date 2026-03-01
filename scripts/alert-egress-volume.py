#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict


LOG_PATTERN = re.compile(
    r"remote_addr=(?P<ip>\S+)\s+time=(?P<time>\S+)\s+content_length=(?P<content_length>\S+)\s+request_length=(?P<request_length>\d+)\s+status=(?P<status>\d+)\s+method=(?P<method>\S+)\s+uri=(?P<uri>\S+)"
)


def run_kubectl(args: list[str]) -> str:
    proc = subprocess.run(
        ["kubectl", *args],
        check=False,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        print(f"kubectl {' '.join(args)} failed:\n{proc.stderr}", file=sys.stderr)
        sys.exit(1)
    return proc.stdout


def load_workspace_pod_map(namespace: str, label_selector: str) -> dict[str, str]:
    output = run_kubectl(["-n", namespace, "get", "pods", "-l", label_selector, "-o", "json"])
    pods = json.loads(output)
    mapping: dict[str, str] = {}
    for item in pods.get("items", []):
        pod_ip = item.get("status", {}).get("podIP")
        pod_name = item.get("metadata", {}).get("name", "unknown")
        if pod_ip:
            mapping[pod_ip] = pod_name
    return mapping


def load_proxy_logs(namespace: str, deployment: str, since: str) -> str:
    return run_kubectl(["-n", namespace, "logs", f"deployment/{deployment}", "--since", since])


def format_bytes(byte_count: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(byte_count)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.2f}{unit}"
        value /= 1024.0
    return f"{byte_count}B"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Alert on per-workspace egress volume based on proxy request sizes."
    )
    parser.add_argument("--namespace", default="coder-secure")
    parser.add_argument("--proxy-deployment", default="dlp-egress-proxy")
    parser.add_argument("--workspace-label", default="app.kubernetes.io/name=coder-workspace")
    parser.add_argument("--window", default="1h", help="kubectl log window, e.g. 1h, 30m")
    parser.add_argument("--threshold-mb", type=float, default=200.0)
    args = parser.parse_args()

    threshold_bytes = int(args.threshold_mb * 1024 * 1024)
    ip_to_workspace = load_workspace_pod_map(args.namespace, args.workspace_label)
    raw_logs = load_proxy_logs(args.namespace, args.proxy_deployment, args.window)

    egress_by_ip: dict[str, int] = defaultdict(int)
    lines = [line for line in raw_logs.splitlines() if line.strip()]
    for line in lines:
        match = LOG_PATTERN.search(line)
        if not match:
            continue
        ip = match.group("ip")
        content_length = match.group("content_length")
        if content_length.isdigit():
            bytes_counted = int(content_length)
        else:
            # Fallback for methods without body or missing content-length.
            bytes_counted = int(match.group("request_length"))
        egress_by_ip[ip] += bytes_counted

    if not egress_by_ip:
        print(
            f"No proxy egress events parsed in namespace={args.namespace} over window={args.window}."
        )
        sys.exit(0)

    print(
        f"Egress volume report (namespace={args.namespace}, window={args.window}, threshold={args.threshold_mb}MB)"
    )
    print("-" * 88)
    print(f"{'Workspace Pod':45} {'Pod IP':16} {'Bytes':>12} {'Human':>10}  Status")

    alerts = 0
    for ip, total_bytes in sorted(egress_by_ip.items(), key=lambda x: x[1], reverse=True):
        workspace = ip_to_workspace.get(ip, "non-workspace-or-unmapped")
        status = "ALERT" if total_bytes >= threshold_bytes else "OK"
        if status == "ALERT":
            alerts += 1
        print(
            f"{workspace[:45]:45} {ip:16} {total_bytes:12d} {format_bytes(total_bytes):>10}  {status}"
        )

    print("-" * 88)
    if alerts:
        print(f"ALERT: {alerts} workspace(s) exceeded {args.threshold_mb}MB in {args.window}.")
        sys.exit(2)

    print("OK: no workspace exceeded the egress threshold.")
    sys.exit(0)


if __name__ == "__main__":
    main()
