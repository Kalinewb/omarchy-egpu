#!/usr/bin/env python3
"""Validate JSON documents against a JSON Schema.

    validate.py <schema.json> [file ...]     (stdin when no file; one document
                                             per line when the input is JSON lines)

Uses the `jsonschema` package when it is installed. Otherwise a small draft-07
subset in the standard library: type, enum, const, properties, required,
additionalProperties, items, minimum, maximum, minLength, pattern, anyOf,
oneOf, allOf and local $ref. That is every keyword tests/schema/status-1.json
uses; an unknown keyword is an error rather than silently ignored.

Exit 0 when every document is valid, 1 otherwise (errors on stderr).
"""

import json
import re
import sys

KNOWN = {
    "$schema", "$id", "title", "description", "definitions", "$defs",
    "type", "enum", "const", "properties", "required", "additionalProperties",
    "items", "minimum", "maximum", "minLength", "pattern", "anyOf", "oneOf",
    "allOf", "$ref",
}

TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
}


def resolve(root, ref):
    if not ref.startswith("#/"):
        raise ValueError(f"only local $ref supported: {ref}")
    node = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def check(root, schema, value, path, errors):
    unknown = set(schema) - KNOWN
    if unknown:
        errors.append(f"{path}: schema uses unsupported keyword(s) {sorted(unknown)}")
        return
    if "$ref" in schema:
        check(root, resolve(root, schema["$ref"]), value, path, errors)
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(TYPES[t](value) for t in types):
            errors.append(f"{path}: {json.dumps(value)[:60]} is not of type {types}")
            return
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: {value!r} != const {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in {schema['enum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if TYPES["number"](value):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} < {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} > {schema['maximum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required '{key}'")
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key in props:
                check(root, props[key], sub, f"{path}.{key}", errors)
            elif "additionalProperties" in schema:
                extra = schema["additionalProperties"]
                if extra is False:
                    errors.append(f"{path}: unexpected '{key}'")
                elif isinstance(extra, dict):
                    check(root, extra, sub, f"{path}.{key}", errors)
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            check(root, schema["items"], item, f"{path}[{i}]", errors)
    for key in ("anyOf", "oneOf"):
        if key in schema:
            ok = 0
            for sub in schema[key]:
                e = []
                check(root, sub, value, path, e)
                ok += not e
            if (key == "anyOf" and ok == 0) or (key == "oneOf" and ok != 1):
                errors.append(f"{path}: {key} matched {ok} branch(es)")
    for sub in schema.get("allOf", []):
        check(root, sub, value, path, errors)


def documents(text):
    text = text.strip()
    if not text:
        return []
    try:
        return [json.loads(text)]
    except json.JSONDecodeError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1]) as f:
        schema = json.load(f)
    inputs = sys.argv[2:] or ["-"]
    try:
        import jsonschema  # type: ignore
        validator = jsonschema.Draft7Validator(schema)
    except ImportError:
        validator = None
    bad = 0
    count = 0
    for name in inputs:
        text = sys.stdin.read() if name == "-" else open(name).read()
        for n, doc in enumerate(documents(text)):
            count += 1
            if validator is not None:
                errors = [f"{'/'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(doc)]
            else:
                errors = []
                check(schema, schema, doc, "$", errors)
            if errors:
                bad += 1
                for e in errors[:20]:
                    print(f"{name}#{n}: {e}", file=sys.stderr)
    if count == 0:
        print("no documents", file=sys.stderr)
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
