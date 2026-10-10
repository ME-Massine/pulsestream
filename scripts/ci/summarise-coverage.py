#!/usr/bin/env python3
"""Render a JaCoCo CSV report as a Markdown table for a CI job summary."""

import csv
import sys


def totals(report_path):
    """Sum JaCoCo counters across all classes in a CSV report."""
    aggregated = {}
    with open(report_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        counters = [
            column[: -len("_MISSED")]
            for column in reader.fieldnames or []
            if column.endswith("_MISSED")
        ]
        for row in reader:
            for counter in counters:
                missed, covered = aggregated.get(counter, (0, 0))
                aggregated[counter] = (
                    missed + int(row[counter + "_MISSED"]),
                    covered + int(row[counter + "_COVERED"]),
                )
    return aggregated


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <jacoco.csv> <service>", file=sys.stderr)
        return 2

    report_path, service = argv[1], argv[2]
    aggregated = totals(report_path)

    lines = [
        f"### Coverage - {service}",
        "",
        "| Counter | Covered | Missed | Ratio |",
        "| --- | ---: | ---: | ---: |",
    ]
    for counter, (missed, covered) in sorted(aggregated.items()):
        total = missed + covered
        ratio = covered / total if total else 1.0
        lines.append(f"| {counter} | {covered} | {missed} | {ratio:.2%} |")
    lines.append("")

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
