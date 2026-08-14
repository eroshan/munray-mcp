#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import sys


def find_root(path: pathlib.Path) -> pathlib.Path:
    p = path.parent.resolve()
    while True:
        if (p / "Cargo.toml").exists():
            return p
        if p.parent == p:
            return path.parent.resolve()
        p = p.parent


def send(proc, message):
    body = json.dumps(message).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    proc.stdin.write(header)
    proc.stdin.write(body)
    proc.stdin.flush()


def recv(proc):
    headers = {}

    while True:
        line = proc.stdout.readline()

        if not line:
            raise EOFError("rust-analyzer exited unexpectedly")

        if line == b"\r\n":
            break

        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()

    length = int(headers["content-length"])
    body = proc.stdout.read(length)
    return json.loads(body)


def wait_for_response(proc, request_id):
    while True:
        msg = recv(proc)

        if msg.get("id") == request_id and ("result" in msg or "error" in msg):
            return msg

        # rust-analyzer may send requests to the client.
        if "method" in msg and "id" in msg:
            method = msg["method"]

            if method == "workspace/configuration":
                items = msg.get("params", {}).get("items", [])
                result = [None for _ in items]
            elif method == "client/registerCapability":
                result = None
            elif method == "window/workDoneProgress/create":
                result = None
            else:
                result = None

            send(
                proc,
                {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "result": result,
                },
            )


SYMBOL_KINDS = {
    1: "File",
    2: "Module",
    3: "Namespace",
    4: "Package",
    5: "Class",
    6: "Method",
    7: "Property",
    8: "Field",
    9: "Constructor",
    10: "Enum",
    11: "Interface",
    12: "Function",
    13: "Variable",
    14: "Constant",
    15: "String",
    16: "Number",
    17: "Boolean",
    18: "Array",
    19: "Object",
    20: "Key",
    21: "Null",
    22: "EnumMember",
    23: "Struct",
    24: "Event",
    25: "Operator",
    26: "TypeParameter",
}


def print_tree(symbols, prefix=""):
    for i, symbol in enumerate(symbols):
        last = i == len(symbols) - 1
        branch = "└── " if last else "├── "

        name = symbol.get("name", "<unknown>")
        detail = symbol.get("detail")
        kind = SYMBOL_KINDS.get(symbol.get("kind"), "")

        suffix = ""

        if detail:
            suffix = f"  {detail}"
        elif kind:
            suffix = f"  [{kind}]"

        print(prefix + branch + name + suffix)

        children = symbol.get("children", [])
        if children:
            print_tree(
                children,
                prefix + ("    " if last else "│   "),
            )


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} FILE.rs", file=sys.stderr)
        sys.exit(2)

    file_path = pathlib.Path(sys.argv[1]).resolve()

    if not file_path.exists():
        print(f"error: file not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    root = find_root(file_path)

    try:
        proc = subprocess.Popen(
            ["rust-analyzer"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print(
            "error: rust-analyzer not found in PATH",
            file=sys.stderr,
        )
        sys.exit(1)

    file_uri = file_path.as_uri()
    root_uri = root.as_uri()

    # Initialize LSP
    send(
        proc,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "processId": os.getpid(),
                "rootUri": root_uri,
                "workspaceFolders": [
                    {
                        "uri": root_uri,
                        "name": root.name,
                    }
                ],
                "capabilities": {
                    "textDocument": {
                        "documentSymbol": {
                            "hierarchicalDocumentSymbolSupport": True
                        }
                    }
                },
            },
        },
    )

    response = wait_for_response(proc, 1)

    if "error" in response:
        print(response["error"], file=sys.stderr)
        proc.kill()
        sys.exit(1)

    send(
        proc,
        {
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": {},
        },
    )

    text = file_path.read_text(encoding="utf-8")

    # Tell rust-analyzer the document is open.
    send(
        proc,
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": file_uri,
                    "languageId": "rust",
                    "version": 1,
                    "text": text,
                }
            },
        },
    )

    # Request the outline.
    send(
        proc,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "textDocument/documentSymbol",
            "params": {
                "textDocument": {
                    "uri": file_uri,
                }
            },
        },
    )

    response = wait_for_response(proc, 2)

    if "error" in response:
        print(
            "rust-analyzer error:",
            response["error"],
            file=sys.stderr,
        )
        proc.kill()
        sys.exit(1)

    symbols = response.get("result") or []

    print(file_path.name)
    print_tree(symbols)

    send(
        proc,
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "shutdown",
            "params": None,
        },
    )

    try:
        wait_for_response(proc, 3)
        send(
            proc,
            {
                "jsonrpc": "2.0",
                "method": "exit",
                "params": None,
            },
        )
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
