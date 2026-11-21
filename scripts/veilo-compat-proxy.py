#!/usr/bin/env python3
"""Local compatibility proxy for OpenAI-compatible gateways that stream
`content` as an array of structured parts instead of a plain string.

The veilo/codex gateway (https://codex.veilo.dev/v1) returns assistant content as
an array whenever reasoning is enabled, for example:

    "content": [
        {"type": "thinking", "thinking": [{"type": "text", "text": "..."}], "closed": true},
        {"type": "text", "text": "final answer"}
    ]

pi-ai's `openai-completions` transport expects `delta.content` and
`message.content` to be plain strings and a separate `reasoning_content` string,
so any request that turns reasoning on fails with
`text-delta text must be a string`.

This proxy rewrites the gateway's array shape into the standard OpenAI shape:
`thinking` parts become `reasoning_content`, `text` parts become `content`.
Both the streaming (SSE) and non-streaming (JSON) responses are handled.
Everything else is forwarded unchanged, so no other provider settings are
affected.

Usage:
    veilo-compat-proxy.py [--host 127.0.0.1] [--port 8081] \
        --upstream https://codex.veilo.dev

Then point the DSH provider's baseURL at http://127.0.0.1:8081/v1 .
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterable


def _thinking_text(part: dict[str, Any]) -> str:
    """Flatten one `thinking` content part into plain text."""
    thinking = part.get("thinking")
    if isinstance(thinking, str):
        return thinking
    if isinstance(thinking, list):
        chunks: list[str] = []
        for item in thinking:
            if isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str):
                    chunks.append(text)
            elif isinstance(item, str):
                chunks.append(item)
        return "".join(chunks)
    return ""


def _split_content_array(content: Iterable[Any]) -> tuple[str, str]:
    """Return (reasoning, text) from an array-shaped content value."""
    reasoning_parts: list[str] = []
    text_parts: list[str] = []
    for part in content:
        if isinstance(part, dict):
            part_type = part.get("type")
            if part_type == "thinking":
                reasoning_parts.append(_thinking_text(part))
            elif part_type == "text":
                text = part.get("text")
                if isinstance(text, str):
                    text_parts.append(text)
            else:
                text = part.get("text")
                if isinstance(text, str):
                    text_parts.append(text)
        elif isinstance(part, str):
            text_parts.append(part)
    return "".join(reasoning_parts), "".join(text_parts)


def normalize_message(message: dict[str, Any]) -> None:
    """Rewrite one `choices[].message` in place when content is an array."""
    content = message.get("content")
    if not isinstance(content, list):
        return
    reasoning, text = _split_content_array(content)
    message["content"] = text
    if reasoning:
        existing = message.get("reasoning_content")
        if not isinstance(existing, str) or not existing:
            message["reasoning_content"] = reasoning


def normalize_delta(delta: dict[str, Any]) -> dict[str, Any] | None:
    """Rewrite one stream `delta` in place; return an optional reasoning delta.

    Array content is collapsed into a plain `content` string, and any thinking
    text is returned as a separate `reasoning_content` payload so the caller can
    emit it as an additional SSE chunk ahead of this one. pi-ai attaches that to
    the thinking block while the text stays a normal string delta.
    """
    content = delta.get("content")
    if not isinstance(content, list):
        return None
    reasoning, text = _split_content_array(content)
    delta["content"] = text
    if reasoning:
        return {"reasoning_content": reasoning}
    return None


def rewrite_stream_line(line: bytes) -> bytes:
    """Rewrite one SSE line if it carries an array-shaped delta."""
    if not line.startswith(b"data:"):
        return line
    payload = line[5:].strip()
    if payload == b"[DONE]" or not payload:
        return line
    try:
        obj = json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        return line
    choices = obj.get("choices")
    if not isinstance(choices, list):
        return line
    emitted: list[bytes] = []
    changed = False
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if not isinstance(delta, dict):
            continue
        content = delta.get("content")
        if not isinstance(content, list):
            continue
        changed = True
        extra = normalize_delta(delta)
        if extra is not None:
            reason_obj = json.loads(json.dumps(obj))
            reason_choice = reason_obj["choices"][0]
            reason_choice["delta"] = {"reasoning_content": extra["reasoning_content"]}
            emitted.append(b"data: " + json.dumps(reason_obj, ensure_ascii=False).encode("utf-8") + b"\n\n")
    if not changed:
        return line
    body = b"data: " + json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n\n"
    return b"".join(emitted) + body


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    verbose = False

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        if self.verbose:
            sys.stderr.write("[proxy] " + fmt % args + "\n")

    def _target_url(self) -> str:
        return self.upstream.rstrip("/") + self.path

    def _forward_headers(self) -> dict[str, str]:
        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lowered = key.lower()
            if lowered in ("host", "content-length", "accept-encoding", "connection"):
                continue
            headers[key] = value
        headers["Accept-Encoding"] = "identity"
        return headers

    def do_GET(self) -> None:  # noqa: N802
        self._proxy(body=None)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        self._proxy(body=body)

    def _proxy(self, body: bytes | None) -> None:
        request = urllib.request.Request(
            self._target_url(), data=body, headers=self._forward_headers(), method=self.command
        )
        try:
            response = urllib.request.urlopen(request, timeout=600)
        except urllib.error.HTTPError as error:
            response = error
        except urllib.error.URLError as error:
            self.send_error(502, f"upstream error: {error}")
            return
        status = getattr(response, "status", 200)
        content_type = response.headers.get("Content-Type", "application/json")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        is_stream = "text/event-stream" in content_type
        if is_stream:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self._stream_chunked(response)
        else:
            raw = response.read()
            raw = self._rewrite_json_body(raw)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    @staticmethod
    def _rewrite_json_body(raw: bytes) -> bytes:
        try:
            obj = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            return raw
        choices = obj.get("choices")
        if isinstance(choices, list):
            for choice in choices:
                if not isinstance(choice, dict):
                    continue
                message = choice.get("message")
                if isinstance(message, dict):
                    normalize_message(message)
        return json.dumps(obj, ensure_ascii=False).encode("utf-8")

    def _stream_chunked(self, response: Any) -> None:
        buffer = b""
        while True:
            chunk = response.read(1024)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                line = line.rstrip(b"\r")
                out = rewrite_stream_line(line)
                self._write_chunk(out + b"\n")
        if buffer:
            self._write_chunk(rewrite_stream_line(buffer.rstrip(b"\r")) + b"\n")
        self._write_chunk(b"")

    def _write_chunk(self, data: bytes) -> None:
        self.wfile.write(b"%X\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--upstream", required=True, help="Upstream base URL, e.g. https://codex.veilo.dev")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    ProxyHandler.upstream = args.upstream
    ProxyHandler.verbose = args.verbose
    server = ThreadingHTTPServer((args.host, args.port), ProxyHandler)
    sys.stderr.write(f"[proxy] {args.host}:{args.port} -> {args.upstream}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
