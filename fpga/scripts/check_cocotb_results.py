#!/usr/bin/env python3
"""Return a failing exit status when a cocotb JUnit report has failures."""

from __future__ import annotations

import argparse
from pathlib import Path
import xml.etree.ElementTree as ET


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    args = parser.parse_args()

    root = ET.parse(args.report).getroot()
    failed = []
    for case in root.findall(".//testcase"):
        if case.find("failure") is not None or case.find("error") is not None:
            failed.append(case.get("name", "unnamed testcase"))
    if failed:
        raise SystemExit("cocotb failures: " + ", ".join(failed))
    print(f"cocotb report passed: {args.report}")


if __name__ == "__main__":
    main()
