#!/usr/bin/env python3
"""Writes Addys15/Sources/BuildSecrets.swift with the ANTHROPIC_API_KEY secret, if the repo has one.
Runs only on the build machine; the key is never committed. Prints nothing about the key itself."""
import json, os, pathlib
key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
path = pathlib.Path(__file__).resolve().parent.parent / "Addys15/Sources/BuildSecrets.swift"
path.write_text("enum BuildSecrets {\n    static let anthropicKey = " + json.dumps(key) + "\n}\n")
print("Claude key built in" if key else "No ANTHROPIC_API_KEY secret: the key is entered in the app's Settings")
