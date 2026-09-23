"""The facts this repo's docs state, and the source each value is computed from.

scripts/doc_facts.py rewrites `<!-- fact:NAME -->VALUE<!-- /fact -->` markers in
tracked .md files from these functions. To add a fact, register it here, wrap the
value in a doc with a marker, and run `make doc-facts`. The full description is
docs/doc-checks.md in the llm-reliability-benchmark repo, where these checks
come from.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from doc_facts_sources import Fact, FactError, regex_group

if TYPE_CHECKING:
    from pathlib import Path

CONFIG = "lib/config.sh"
REVIEWER = "lib/reviewer.sh"
BYTES_PER_KB = 1000


def config_default(root: Path, name: str) -> int:
    """Return the integer default `_set_defaults` in lib/config.sh assigns to `name`."""
    return int(regex_group(root, CONFIG, rf"^\s+{name}=(\d+)\s*$"))


def max_network_retries(root: Path) -> int:
    """Return the default of AUTOPILOT_MAX_NETWORK_RETRIES."""
    return config_default(root, "AUTOPILOT_MAX_NETWORK_RETRIES")


def max_diff_kb(root: Path) -> int:
    """Return the default of AUTOPILOT_MAX_DIFF_BYTES in KB of 1,000 bytes."""
    limit = config_default(root, "AUTOPILOT_MAX_DIFF_BYTES")
    if limit % BYTES_PER_KB:
        raise FactError(f"AUTOPILOT_MAX_DIFF_BYTES={limit} is not a whole number of KB")
    return limit // BYTES_PER_KB


def diff_sample_bytes(root: Path) -> str:
    """Return how many diff bytes the oversized-diff sample keeps, with commas."""
    pattern = r'^\s+printf \'%s\' "\$raw_diff" \| head -c (\d+)\s*$'
    return f"{int(regex_group(root, REVIEWER, pattern)):,}"


def self_update_interval(root: Path) -> int:
    """Return the default of AUTOPILOT_SELF_UPDATE_INTERVAL, in seconds."""
    return config_default(root, "AUTOPILOT_SELF_UPDATE_INTERVAL")


FACTS: dict[str, Fact] = {
    "max-network-retries": Fact(
        f"AUTOPILOT_MAX_NETWORK_RETRIES default in {CONFIG}", max_network_retries
    ),
    "max-diff-kb": Fact(
        f"AUTOPILOT_MAX_DIFF_BYTES default in {CONFIG}, divided by 1,000", max_diff_kb
    ),
    "diff-sample-bytes": Fact(
        f"the `head -c N` byte count of the oversized-diff sample in {REVIEWER}",
        diff_sample_bytes,
    ),
    "self-update-interval": Fact(
        f"AUTOPILOT_SELF_UPDATE_INTERVAL default in {CONFIG}", self_update_interval
    ),
}
