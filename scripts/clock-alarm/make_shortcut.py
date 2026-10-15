#!/usr/bin/env python3
"""Builds "Jarvis Alarm.shortcut": sets an alarm in the macOS Clock app.

Input (text): "<yyyy-MM-dd HH:mm>|<name>", e.g. "2026-10-16 07:00|Jarvis". Jarvis runs it with
`shortcuts run "Jarvis Alarm" -i <file>` for "saat 7'de alarm kur" / "beni uyandır".

The Clock app's "Add Alarm" action (CreateAlarmIntent) has no public API, so a shortcut is the
only way in. Build, sign and import once:
    python3 scripts/clock-alarm/make_shortcut.py && open "scripts/clock-alarm/Jarvis Alarm.shortcut"
then "Add Shortcut". On the first run macOS asks whether the shortcut may use Clock: choose
"Always Allow", otherwise every run waits on that prompt.
"""
import plistlib
import subprocess
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNSIGNED = HERE / "Jarvis Alarm (unsigned).shortcut"
SIGNED = HERE / "Jarvis Alarm.shortcut"


def output(uuid_, name):
    """A text field holding just one earlier action's output."""
    return {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {
        "OutputName": name, "OutputUUID": uuid_, "Type": "ActionOutput"}}},
        "WFSerializationType": "WFTextTokenString"}


split, first, last = (str(uuid.uuid4()).upper() for _ in range(3))
workflow = {
    "WFWorkflowClientVersion": "2607.0.2",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4274264319, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowTypes": [],
    "WFWorkflowImportQuestions": [],
    "WFWorkflowActions": [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.text.split",
         "WFWorkflowActionParameters": {
             "UUID": split,
             "text": {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}}},
                      "WFSerializationType": "WFTextTokenString"},
             "WFTextSeparator": "Custom", "WFTextCustomSeparator": "|"}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.getitemfromlist",
         "WFWorkflowActionParameters": {
             "UUID": first, "WFItemSpecifier": "First Item",
             "WFInput": {"Value": {"OutputName": "Split Text", "OutputUUID": split, "Type": "ActionOutput"},
                         "WFSerializationType": "WFTextTokenAttachment"}}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.getitemfromlist",
         "WFWorkflowActionParameters": {
             "UUID": last, "WFItemSpecifier": "Last Item",
             "WFInput": {"Value": {"OutputName": "Split Text", "OutputUUID": split, "Type": "ActionOutput"},
                         "WFSerializationType": "WFTextTokenAttachment"}}},
        {"WFWorkflowActionIdentifier": "com.apple.clock.CreateAlarmIntent",
         "WFWorkflowActionParameters": {
             "dateComponents": output(first, "Item from List"),
             "name": output(last, "Item from List"),
             "AppIntentDescriptor": {"AppIntentIdentifier": "CreateAlarmIntent", "BundleIdentifier": "com.apple.clock",
                                     "Name": "Clock", "TeamIdentifier": "0000000000"}}},
    ],
}

plistlib.dump(workflow, UNSIGNED.open("wb"), fmt=plistlib.FMT_BINARY)
result = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(UNSIGNED), "--output", str(SIGNED)],
                        capture_output=True, text=True)
UNSIGNED.unlink()
if result.returncode != 0:
    sys.exit(f"shortcuts sign failed: {result.stderr.strip()}")
print(f"Wrote {SIGNED}")
