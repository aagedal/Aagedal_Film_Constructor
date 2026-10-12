#!/usr/bin/env python3
"""Qualify exported .otio structure and timing with the official OTIO core.

Development-only dependency: pip install opentimelineio. No Python is shipped.
"""
import json
import math
import sys
from fractions import Fraction

import opentimelineio as otio


def seconds(value):
    return float(Fraction(value["numerator"], value["denominator"]))


def equal_time(actual, expected):
    assert math.isclose(actual.to_seconds(), expected, rel_tol=1e-12, abs_tol=1e-10), (actual, expected)


def validate(path):
    with open(path, encoding="utf-8") as source:
        exported = json.load(source)
    timeline = otio.adapters.read_from_file(path, adapter_name="otio_json")
    assert isinstance(timeline, otio.schema.Timeline)
    assert isinstance(timeline.tracks, otio.schema.Stack)
    metadata = timeline.metadata["aagedal_film_constructor"]
    rate = seconds(metadata["frame_rate"])
    assert timeline.global_start_time.value == metadata["start_timecode_frames"]
    assert timeline.global_start_time.rate == rate
    equal_time(timeline.global_start_time, metadata["start_timecode_frames"] / rate)
    assert len(timeline.tracks) == len(exported["tracks"]["children"])
    duration = timeline.duration().to_seconds()
    for track, raw in zip(timeline.tracks, exported["tracks"]["children"]):
        assert isinstance(track, otio.schema.Track)
        assert track.kind == raw["kind"]
        assert track.metadata["aagedal_film_constructor"]["track_id"] == raw["metadata"]["aagedal_film_constructor"]["track_id"]
        equal_time(track.duration(), duration)
        assert len(track) == len(raw["children"])
        for child, original in zip(track, raw["children"]):
            assert child.schema_name() == original["OTIO_SCHEMA"].split(".")[0]
            for field in ("start_time", "duration"):
                value = original["source_range"][field]
                equal_time(getattr(child.source_range, field), value["value"] / value["rate"])
            if isinstance(child, otio.schema.Gap):
                continue
            assert isinstance(child, otio.schema.Clip)
            app = child.metadata["aagedal_film_constructor"]
            equal_time(child.range_in_parent().start_time, seconds(app["timeline_start"]))
            equal_time(child.source_range.start_time, seconds(app["source_start"]))
            equal_time(child.source_range.duration, seconds(app["duration"]))
            reference = child.media_reference
            assert isinstance(reference, otio.schema.ExternalReference)
            assert reference.target_url == original["media_references"]["DEFAULT_MEDIA"]["target_url"]
            assert child.name == original["name"]
            # TimeRange.contains(range) requires a strictly preceding start;
            # a trim starting exactly at the media start is valid here.
            assert reference.available_range.start_time.to_seconds() <= child.source_range.start_time.to_seconds() + 1e-10
            assert reference.available_range.end_time_exclusive().to_seconds() + 1e-10 >= child.source_range.end_time_exclusive().to_seconds()
    # Serialize using the official core and read it again; compare all schema fields.
    rewritten = otio.adapters.write_to_string(timeline, adapter_name="otio_json")
    restored = otio.adapters.read_from_string(rewritten, adapter_name="otio_json")
    assert timeline.is_equivalent_to(restored)
    print(f"OTIO {otio.__version__}: core read/write and timing validated: {path}")


if __name__ == "__main__":
    for filename in sys.argv[1:]:
        validate(filename)
