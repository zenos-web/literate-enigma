#!/usr/bin/env python3
"""Expose OpenXPlay's oxp-clink stdio protocol to CarWithin on a trusted LAN."""
import argparse
import ipaddress
from pathlib import Path
import shutil
import socket
import subprocess


def ipv4(value):
    try:
        return str(ipaddress.IPv4Address(value))
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", type=ipv4, required=True, help="relay IPv4 reachable by iPhone")
    parser.add_argument("--phone", type=ipv4, required=True, help="allow this iPhone IPv4 only")
    parser.add_argument("--head-unit", type=ipv4, required=True, help="CarLink head unit IPv4")
    parser.add_argument("--local", type=ipv4, required=True, help="relay IPv4 on the head unit network")
    parser.add_argument("--pin-file", type=Path, required=True, help="file containing the current CarLink PIN")
    parser.add_argument("--state-dir", type=Path, required=True, help="local CarLink pairing data directory")
    parser.add_argument("--binary", default="oxp-clink", help="oxp-clink executable")
    args = parser.parse_args()
    binary = shutil.which(args.binary)
    if binary is None:
        parser.error("oxp-clink executable not found")
    if not args.pin_file.is_file():
        parser.error("--pin-file must point to an existing file")
    command = [
        binary, "--stdio", "--link", "static", "--head-unit", args.head_unit,
        "--local", args.local, "--pin-file", str(args.pin_file), "--state-dir", str(args.state_dir),
    ]
    args.state_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    with socket.create_server((args.listen, 24890), family=socket.AF_INET, backlog=1) as listener:
        print(f"Waiting for CarWithin from {args.phone} on {args.listen}:24890", flush=True)
        while True:
            client, (address, _) = listener.accept()
            with client:
                if address != args.phone:
                    continue
                client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                with subprocess.Popen(command, stdin=client, stdout=client) as process:
                    try:
                        status = process.wait()
                    except KeyboardInterrupt:
                        process.terminate()
                        raise
                if status:
                    print(f"oxp-clink exited with status {status}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
