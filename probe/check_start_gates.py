"""Check the generated start-mask GSUB against timer spellings (no Xcode needed)."""

from __future__ import annotations

import math
from pathlib import Path

from fontTools.ttLib import TTFont

from fontgen import DIGITS


ROOT = Path(__file__).resolve().parent


def timer_text(seconds: int, padded_zero: bool = False) -> str:
    if seconds < 3600:
        minutes, sec = divmod(seconds, 60)
        return f"{minutes:02d}:{sec:02d}" if padded_zero else f"{minutes}:{sec:02d}"
    hours, remainder = divmod(seconds, 3600)
    minutes, sec = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{sec:02d}"


def final_glyph(font: TTFont, value: str) -> str:
    """Run this font's liga chain lookup on a timer string.

    These fonts use only GSUB type 6 format 3 and a type 1 single lookup.
    Backtrack coverages in OpenType are stored nearest to farthest.
    """
    cmap = font.getBestCmap()
    glyphs = [cmap[ord(char)] for char in value]
    gsub = font["GSUB"].table
    feature = next(record.Feature for record in gsub.FeatureList.FeatureRecord
                   if record.FeatureTag == "liga")
    assert feature.LookupListIndex == [0]
    chain = gsub.LookupList.Lookup[0]
    single = gsub.LookupList.Lookup[1]
    assert chain.LookupType == 6 and single.LookupType == 1
    for index in range(len(glyphs)):
        for rule in chain.SubTable:
            assert rule.Format == 3 and rule.InputGlyphCount == 1
            if glyphs[index] not in rule.InputCoverage[0].glyphs:
                continue
            if index < rule.BacktrackGlyphCount:
                continue
            if any(glyphs[index - distance - 1] not in coverage.glyphs
                   for distance, coverage in enumerate(rule.BacktrackCoverage)):
                continue
            if index + rule.LookAheadGlyphCount >= len(glyphs):
                continue
            if any(glyphs[index + distance + 1] not in coverage.glyphs
                   for distance, coverage in enumerate(rule.LookAheadCoverage)):
                continue
            for record in rule.SubstLookupRecord:
                assert record.SequenceIndex == 0 and record.LookupListIndex == 1
                glyphs[index] = single.SubTable[0].mapping[glyphs[index]]
            break  # Ignore substitution also terminates lookup for this glyph.
    return glyphs[-1]


def main() -> None:
    fonts = {
        "open": TTFont(ROOT / "Fonts/WAStartOpen.ttf"),
        "pulse": TTFont(ROOT / "Fonts/WAStartPulse.ttf"),
    }
    for name, font in fonts.items():
        assert font["name"].getDebugName(6) == f"WAStart{name.title()}-Regular"
        assert set(font.getBestCmap()[ord(str(d))] for d in range(10)) == set(DIGITS)
        assert font["glyf"]["full"].numberOfContours > 0
        assert font["glyf"]["empty"].numberOfContours == 0

    checked = 0
    # Countdown immediately before the date, elapsed time through the first
    # day, and both plausible zero spellings are checked against the GSUB data.
    for seconds in range(24 * 3600 + 1):
        for padded in ((False, True) if seconds == 0 else (False,)):
            value = timer_text(seconds, padded)
            expected_open = "empty" if seconds == 0 else DIGITS[int(value[-1])]
            expected_pulse = "full" if seconds == 0 else DIGITS[int(value[-1])]
            assert final_glyph(fonts["open"], value) == expected_open, ("open", value)
            assert final_glyph(fonts["pulse"], value) == expected_pulse, ("pulse", value)
            checked += 1
    for seconds in (3, 2, 1):
        value = timer_text(seconds)
        assert final_glyph(fonts["open"], value) != "empty", value
        assert final_glyph(fonts["pulse"], value) != "full", value
    for elapsed in (0.0, 0.10, 0.24, 0.25, 0.26, 0.99, 1.0):
        # Model Text(.timer): ceil until the target, floor after it.
        first = timer_text(math.floor(elapsed))
        second = timer_text(math.ceil(0.25 - elapsed) if elapsed < 0.25
                            else math.floor(elapsed - 0.25))
        visible = (final_glyph(fonts["open"], first) != "empty" or
                   final_glyph(fonts["pulse"], second) == "full")
        assert visible == (elapsed >= 0.25), (elapsed, first, second)
    print(f"GSUB OK: {checked} elapsed spellings (0:00..24:00:00), countdown 0:03..0:01")


if __name__ == "__main__":
    main()
