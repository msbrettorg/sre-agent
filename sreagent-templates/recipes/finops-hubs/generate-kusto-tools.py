#!/usr/bin/env python3
"""Generate Azure SRE Agent Kusto tools from the FinOps Toolkit query catalog."""

from __future__ import annotations

import argparse
import pathlib
import re
from typing import Any

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required. Install with: pip install pyyaml") from exc


JsonObject = dict[str, Any]


class LiteralString(str):
    """String serialized as a YAML literal block."""


class ToolDumper(yaml.SafeDumper):
    pass


def represent_literal(dumper: yaml.SafeDumper, value: LiteralString) -> yaml.ScalarNode:
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style="|")


ToolDumper.add_representer(LiteralString, represent_literal)


def read_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def read_kql_body(path: pathlib.Path) -> str:
    lines = read_text(path).splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped and not stripped.startswith("//"):
            return "\n".join(lines[index:]).rstrip()
    raise SystemExit(f"Kusto query contains no executable content: {path}")


def collect_kql_comment_block(path: pathlib.Path) -> list[str]:
    comments: list[str] = []
    for line in read_text(path).splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("//"):
            break
        comments.append(stripped[2:].strip())
    return comments


def kql_description(path: pathlib.Path) -> str:
    comments = collect_kql_comment_block(path)
    query_name = path.stem.replace("-", " ")
    description_lines: list[str] = []
    in_description = False

    for comment in comments:
        if comment == "Description:":
            in_description = True
            continue
        if comment == "Parameters:" or comment.startswith("Query:"):
            if in_description:
                break
            if comment.startswith("Query:"):
                query_name = comment.split(":", 1)[1].strip() or query_name
            continue
        if in_description:
            description_lines.append(comment)

    description = " ".join(part for part in description_lines if part)
    return description or f"Runs the {query_name} FinOps Hub catalog query."


def kql_parameters(path: pathlib.Path) -> list[JsonObject]:
    comments = collect_kql_comment_block(path)
    query = read_kql_body(path)
    parameters: list[JsonObject] = []
    in_parameters = False

    for comment in comments:
        if comment == "Parameters:":
            in_parameters = True
            continue
        if not in_parameters:
            continue
        if comment.startswith("Each row") or comment.startswith("Use this query"):
            break
        if comment.lower().startswith("none"):
            break
        if ":" not in comment:
            continue

        name, raw_description = comment.split(":", 1)
        name = name.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            continue
        if not re.search(rf"^let\s+{re.escape(name)}\s*=", query, flags=re.MULTILINE):
            continue
        if any(parameter["name"] == name for parameter in parameters):
            continue

        parameters.append(
            {
                "name": name,
                "type": "string",
                "description": raw_description.strip(),
                "required": True,
            }
        )

    return parameters


def replace_kql_parameter_defaults(query: str, parameters: list[JsonObject]) -> str:
    for parameter in parameters:
        name = re.escape(str(parameter["name"]))
        query = re.sub(
            rf"^let\s+{name}\s*=\s*[^;\n]+;",
            f"let {parameter['name']} = ##{parameter['name']}##;",
            query,
            count=1,
            flags=re.MULTILINE,
        )
    return query


def build_tool(path: pathlib.Path) -> JsonObject:
    parameters = kql_parameters(path)
    query = replace_kql_parameter_defaults(read_kql_body(path), parameters)
    spec: JsonObject = {
        "type": "KustoTool",
        "mode": "Query",
        "connector": "finops-hub-kusto",
        "description": kql_description(path),
        "database": "Hub",
        "query": LiteralString(query),
    }
    if parameters:
        spec["parameters"] = parameters

    return {
        "api_version": "azuresre.ai/v2",
        "kind": "ExtendedAgentTool",
        "metadata": {"name": path.stem},
        "spec": spec,
    }


def remove_stale_kusto_tools(output_dir: pathlib.Path, current_names: set[str]) -> None:
    for path in sorted(output_dir.glob("*.y*ml")):
        with path.open("r", encoding="utf-8") as handle:
            manifest = yaml.safe_load(handle) or {}
        if not isinstance(manifest, dict):
            continue
        spec = manifest.get("spec") or {}
        if spec.get("type") != "KustoTool":
            continue
        name = str((manifest.get("metadata") or {}).get("name") or path.stem)
        if name not in current_names:
            path.unlink()


def parse_args() -> argparse.Namespace:
    recipe_dir = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--catalog-dir",
        type=pathlib.Path,
        required=True,
        help="Path to the FinOps Toolkit src/queries/catalog directory.",
    )
    parser.add_argument(
        "--output-dir",
        type=pathlib.Path,
        default=recipe_dir / "config/tools",
        help="Destination for generated Kusto tool YAML.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    catalog_dir = args.catalog_dir.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    query_paths = sorted(catalog_dir.glob("*.kql"))
    if not catalog_dir.is_dir() or not query_paths:
        raise SystemExit(f"FinOps Toolkit query catalog not found or empty: {catalog_dir}")

    output_dir.mkdir(parents=True, exist_ok=True)
    current_names = {path.stem for path in query_paths}
    remove_stale_kusto_tools(output_dir, current_names)

    for query_path in query_paths:
        output_path = output_dir / f"{query_path.stem}.yaml"
        output_path.write_text(
            yaml.dump(
                build_tool(query_path),
                Dumper=ToolDumper,
                sort_keys=False,
                allow_unicode=False,
                width=120,
            ),
            encoding="utf-8",
        )

    print(f"Generated {len(query_paths)} Kusto tools in {output_dir}")


if __name__ == "__main__":
    main()
