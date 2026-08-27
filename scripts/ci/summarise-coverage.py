#!/usr/bin/env python3
"""Render a JaCoCo CSV report as a Markdown table for the CI job summary.

The XML/HTML reports are uploaded as artifacts; this exists so the numbers are
readable without downloading anything, and so a coverage change is visible in
the run itself rather than only in the pass/fail of the JaCoCo check rule.

    python3 scripts/ci/summarise-coverage.py \
        services/query-service/target/site/jacoco/jacoco.csv query-service
"""

import csv
import sys


def totals(report_path):
    """Sum every counter across the classes in a JaCoCo CSV report.

    The counter set is read from the header rather than hard-coded: JaCoCo emits
    INSTRUCTION, BRANCH, LINE, COMPLEXITY and METHOD today, and a report with a
    different set should still summarise instead of raising a KeyError.
    """
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

    lines = [f"### Coverage - {service}", "", "| Counter | Covered | Missed | Ratio |", "| --- | ---: | ---: | ---: |"]
    for counter, (missed, covered) in sorted(aggregated.items()):
        total = missed + covered
        ratio = covered / total if total else 1.0
        lines.append(f"| {counter} | {covered} | {missed} | {ratio:.2%} |")
    lines.append("")

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
