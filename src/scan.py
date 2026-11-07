#!/usr/bin/env python3
"""Scan BLE advertisements on macOS and dump everything we see."""
import asyncio
import sys
import time
from bleak import BleakScanner

FILTER = [s.lower() for s in (sys.argv[1:] or [])]
DURATION = 15.0


def hexs(b):
    return " ".join(f"{x:02x}" for x in b) if b else ""


def main():
    seen = {}

    def cb(dev, adv):
        key = dev.address
        entry = seen.setdefault(key, {"first": time.time(), "n": 0})
        entry["n"] += 1
        entry["dev"] = dev
        entry["adv"] = adv

    async def run():
        scanner = BleakScanner(detection_callback=cb)
        await scanner.start()
        await asyncio.sleep(DURATION)
        await scanner.stop()

    asyncio.run(run())

    for addr, e in sorted(seen.items(), key=lambda kv: (kv[1]["dev"].name or "zz")):
        dev, adv = e["dev"], e["adv"]
        name = dev.name or ""
        if FILTER and not any(f in name.lower() for f in FILTER):
            continue
        print(f"\n=== {name or '<no name>'}  [{addr}] rssi={adv.rssi} hits={e['n']}")
        print(f"  service_uuids : {adv.service_uuids}")
        if adv.service_data:
            for k, v in adv.service_data.items():
                print(f"  service_data  {k} : {hexs(v)}")
        if adv.manufacturer_data:
            for k, v in adv.manufacturer_data.items():
                print(f"  mfr_data      0x{k:04x} ({k}) : {hexs(v)}")


if __name__ == "__main__":
    main()
