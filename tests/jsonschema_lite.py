"""Minimal JSON Schema validator for the keywords used in docs/api/*.schema.json.

Standard library only (the Core has no third-party dependencies). Supported:
type, enum, const, properties, required, additionalProperties (false),
items, anyOf, $ref (local "#/$defs/..."), minimum, pattern. An unsupported
keyword raises, so the schema cannot silently use something unchecked.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List

_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}
_ANNOTATIONS = {"$schema", "$id", "title", "description", "$defs", "x-command-data"}
_SUPPORTED = _ANNOTATIONS | {"type", "enum", "const", "properties", "required", "additionalProperties",
                             "items", "anyOf", "$ref", "minimum", "pattern"}


def validate(instance: Any, schema: Dict[str, Any], root: Dict[str, Any], path: str = "$") -> List[str]:
    errors: List[str] = []
    unknown = set(schema) - _SUPPORTED
    if unknown:
        raise ValueError(f"unsupported schema keywords at {path}: {sorted(unknown)}")
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/$defs/"):
            raise ValueError(f"unsupported $ref {ref}")
        return validate(instance, root["$defs"][ref[len("#/$defs/"):]], root, path)
    if "anyOf" in schema:
        if not any(not validate(instance, s, root, path) for s in schema["anyOf"]):
            errors.append(f"{path}: matches none of anyOf")
        return errors
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_TYPES[t](instance) for t in types):
            return [f"{path}: expected {types}, got {type(instance).__name__}"]
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} not in enum")
    if "minimum" in schema and isinstance(instance, (int, float)) and not isinstance(instance, bool) \
            and instance < schema["minimum"]:
        errors.append(f"{path}: {instance} < minimum {schema['minimum']}")
    if "pattern" in schema and isinstance(instance, str) and not re.search(schema["pattern"], instance):
        errors.append(f"{path}: {instance!r} does not match {schema['pattern']}")
    if isinstance(instance, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required '{key}'")
        if schema.get("additionalProperties") is False:
            for key in instance:
                if key not in props:
                    errors.append(f"{path}: unexpected property '{key}'")
        for key, sub in props.items():
            if key in instance:
                errors += validate(instance[key], sub, root, f"{path}.{key}")
    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            errors += validate(item, schema["items"], root, f"{path}[{i}]")
    return errors


def validate_response(doc: Any, schema: Dict[str, Any]) -> List[str]:
    """Validate an API envelope and, when present, its command-specific data."""
    errors = validate(doc, schema, schema)
    if errors or not isinstance(doc, dict) or doc.get("data") is None:
        return errors
    data_def = schema["x-command-data"].get(doc.get("command"))
    if data_def is None:
        return [f"$.command: no data schema for {doc.get('command')!r}"]
    return validate(doc["data"], schema["$defs"][data_def], schema, "$.data")
