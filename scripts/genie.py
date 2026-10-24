#!/usr/bin/env python3
"""Consulta e avalia o Genie Farol · Diretoria com o perfil Databricks indicado."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def cli(args: list[str], profile: str) -> dict:
    result = subprocess.run(
        ["databricks", *args, "--profile", profile, "-o", "json"],
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout or "{}")


def space_id(title: str, profile: str) -> str:
    token = None
    matches: list[dict] = []
    while True:
        args = ["genie", "list-spaces", "--page-size", "100"]
        if token:
            args.extend(["--page-token", token])
        response = cli(args, profile)
        spaces = response if isinstance(response, list) else response.get("spaces", [])
        matches.extend(space for space in spaces if space.get("title") == title)
        token = response.get("next_page_token") if isinstance(response, dict) else None
        if not token:
            break
    if len(matches) != 1:
        raise RuntimeError(f"Esperava um espaço chamado {title!r}, encontrei {len(matches)}")
    return matches[0]["space_id"]


def ask(space: str, question: str, profile: str) -> dict:
    response = cli(["genie", "start-conversation", space, question], profile)
    if response.get("status") not in (None, "COMPLETED"):
        raise RuntimeError(f"Genie terminou em {response.get('status')}: {response.get('error')}")
    if not response.get("attachments") and response.get("conversation_id") and response.get("message_id"):
        response = cli([
            "genie", "get-message", space,
            response["conversation_id"], response["message_id"],
        ], profile)
    return response


def visible_text(message: dict) -> str:
    # `content` devolvido pela API é a pergunta do usuário, não a resposta.
    parts: list[str] = []
    for attachment in message.get("attachments", []):
        query = attachment.get("query") or {}
        text = attachment.get("text") or {}
        parts.extend([str(query.get("query") or ""), str(text.get("content") or "")])
    return "\n".join(parts)


def benchmark(space: str, path: Path, profile: str) -> int:
    cases = json.loads(path.read_text(encoding="utf-8"))["questions"]
    if len(cases) != 20:
        raise ValueError(f"Benchmark esperado: 20 perguntas, encontrei {len(cases)}")
    passed = 0
    for index, case in enumerate(cases, 1):
        question = case["question"]
        try:
            response = ask(space, question, profile)
            output = visible_text(response)
            missing = [pattern for pattern in case["required_patterns"]
                       if not re.search(pattern, output, re.IGNORECASE | re.DOTALL)]
            forbidden = [pattern for pattern in case.get("forbidden_patterns", [])
                         if re.search(pattern, output, re.IGNORECASE | re.DOTALL)]
            success = response.get("status") != "FAILED" and bool(output.strip()) and not missing and not forbidden
            passed += int(success)
            print(f"[{index:02d}/20] {'OK' if success else 'ERRO'} {question}")
            if not success:
                print(f"  ausentes: {missing}; proibidos: {forbidden}; status: {response.get('status')}")
                print(f"  resposta: {output[:1200]}")
        except (RuntimeError, KeyError, ValueError) as exc:
            print(f"[{index:02d}/20] ERRO {question}\n  {exc}")
    print(f"Resultado: {passed}/20")
    return 0 if passed >= 16 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    question_command = commands.add_parser("perguntar")
    question_command.add_argument("title")
    question_command.add_argument("question")
    question_command.add_argument("--profile", required=True)
    benchmark_command = commands.add_parser("benchmark")
    benchmark_command.add_argument("title")
    benchmark_command.add_argument("path", type=Path)
    benchmark_command.add_argument("--profile", required=True)
    args = parser.parse_args()
    space = space_id(args.title, args.profile)
    if args.command == "perguntar":
        response = ask(space, args.question, args.profile)
        print(json.dumps(response, ensure_ascii=False, indent=2))
        return 0 if response.get("status") != "FAILED" else 1
    return benchmark(space, args.path, args.profile)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, KeyError) as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        sys.exit(1)
