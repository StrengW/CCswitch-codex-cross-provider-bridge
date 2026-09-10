#!/usr/bin/env python3
"""Adaptive provider-neutral bridge for Codex Responses requests.

The bridge performs a conservative provider-state cleanup first. If the target
rejects provider-owned history, it automatically retries once with a portable
replay that keeps messages and tool calls/results but omits reasoning state.
It is intended to sit between Codex and a local CC Switch proxy.  When the
official route is active, an optional model override can also replace the
top-level request model.  This is useful when resuming a session recorded with
a third-party model: Codex may keep the old model in the replay request even
after the UI has been switched to an official model.
"""

from __future__ import annotations

import argparse
import http.client
import json
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

PORTABILITY_ERROR_MARKERS = (
    b"invalid 'input[",
    b'invalid "input[',
    b"encrypted content",
    b"could not be verified",
    b"expected an id that begins",
    b"array too long",
    b"previous_response_id",
)


def neutralize_responses_payload(payload: object) -> tuple[object, int, int, int, bool]:
    """Neutralize provider-owned fields without touching message or call data."""
    if not isinstance(payload, dict):
        return payload, 0, 0, 0, False

    cleaned = dict(payload)
    removed = 0
    cleared_reasoning_content = 0
    removed_foreign_encrypted_content = 0
    previous_removed = False

    items = cleaned.get("input")
    if isinstance(items, list):
        neutral_items = []
        for item in items:
            if isinstance(item, dict):
                item = dict(item)
                original_id = item.get("id")
                if "id" in item:
                    item.pop("id", None)
                    removed += 1

                # Some third-party providers serialize visible reasoning text
                # into reasoning.content. OpenAI accepts this field on replay
                # only as an empty array. Keep the reasoning item and all of
                # its other fields, but neutralize the provider-specific text.
                content = item.get("content")
                foreign_reasoning = item.get("type") == "reasoning" and (
                    (isinstance(content, list) and bool(content))
                    or (
                        isinstance(original_id, str)
                        and not original_id.startswith("rs_")
                    )
                )
                if foreign_reasoning:
                    if isinstance(content, list) and content:
                        item["content"] = []
                        cleared_reasoning_content += 1

                    # encrypted_content is opaque provider-owned state. If
                    # this reasoning item came from a provider that emitted
                    # visible reasoning content, its ciphertext cannot be
                    # verified by a different provider either.
                    if "encrypted_content" in item:
                        item.pop("encrypted_content", None)
                        removed_foreign_encrypted_content += 1
            neutral_items.append(item)
        cleaned["input"] = neutral_items

    # A response ID belongs to the provider that created it and cannot safely
    # be replayed after changing providers.
    if cleaned.get("previous_response_id") is not None:
        cleaned.pop("previous_response_id", None)
        previous_removed = True

    # With full input replay, store=false prevents the next provider from
    # requiring server-side state from the previous provider.
    cleaned["store"] = False
    return (
        cleaned,
        removed,
        cleared_reasoning_content,
        removed_foreign_encrypted_content,
        previous_removed,
    )


def override_responses_model(
    payload: object, model_override: str
) -> tuple[object, str | None, bool]:
    """Replace a replay request's model when an explicit target is configured.

    The bridge never guesses a target model.  The manager/user must provide it
    explicitly, because model names and availability differ between accounts.
    Requests without a string ``model`` are left untouched rather than having
    a new field invented for an otherwise valid provider request.
    """
    if not model_override or not isinstance(payload, dict):
        return payload, None, False

    original_model = payload.get("model")
    if not isinstance(original_model, str) or original_model == model_override:
        return payload, original_model if isinstance(original_model, str) else None, False

    rewritten = dict(payload)
    rewritten["model"] = model_override
    return rewritten, original_model, True


def make_portable_responses_payload(payload: object) -> tuple[object, int, int, bool]:
    """Build a provider-neutral replay after a target rejects opaque state.

    Human/assistant messages and tool calls/results remain intact. Reasoning and
    item-reference records are provider-owned continuation state, so the
    fallback omits them instead of attempting to translate opaque contents.
    """
    if not isinstance(payload, dict):
        return payload, 0, 0, False

    cleaned = dict(payload)
    removed_item_ids = 0
    omitted_provider_items = 0
    previous_removed = False
    items = cleaned.get("input")

    if isinstance(items, list):
        portable_items = []
        for original in items:
            if not isinstance(original, dict):
                portable_items.append(original)
                continue

            item = dict(original)
            item_type = item.get("type")
            if item_type in {"reasoning", "item_reference"}:
                omitted_provider_items += 1
                continue

            if "id" in item:
                item.pop("id", None)
                removed_item_ids += 1
            # Defensive cleanup for providers that attach opaque state to a
            # non-reasoning output item.
            item.pop("encrypted_content", None)
            portable_items.append(item)
        cleaned["input"] = portable_items

    if cleaned.get("previous_response_id") is not None:
        cleaned.pop("previous_response_id", None)
        previous_removed = True
    cleaned["store"] = False
    return cleaned, removed_item_ids, omitted_provider_items, previous_removed


def is_portability_error(status: int, body: bytes) -> bool:
    if status != 400:
        return False
    lowered = body.lower()
    return any(marker in lowered for marker in PORTABILITY_ERROR_MARKERS)


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CodexProviderBridge/2.1"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _handle(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(content_length) if content_length else b""
        encoding = (self.headers.get("Content-Encoding") or "").lower().strip()

        if encoding and encoding != "identity":
            self.send_error(
                415,
                "Compressed request body is unsupported. Set "
                "[features] enable_request_compression = false in config.toml.",
            )
            return

        removed = 0
        cleared_reasoning_content = 0
        removed_foreign_encrypted_content = 0
        previous_removed = False
        original_payload: object | None = None
        original_model: str | None = None
        model_rewritten = False
        content_type = (self.headers.get("Content-Type") or "").lower()
        if body and "json" in content_type and self.path.rstrip("/").endswith("responses"):
            try:
                original_payload = json.loads(body.decode("utf-8"))
                original_payload, original_model, model_rewritten = override_responses_model(
                    original_payload,
                    self.server.model_override,  # type: ignore[attr-defined]
                )
                (
                    payload,
                    removed,
                    cleared_reasoning_content,
                    removed_foreign_encrypted_content,
                    previous_removed,
                ) = neutralize_responses_payload(original_payload)
                body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                self.send_error(400, f"Invalid JSON request body: {exc}")
                return

        upstream = self.server.upstream  # type: ignore[attr-defined]
        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP or lower in {"host", "content-length", "accept-encoding"}:
                continue
            headers[key] = value
        # Error bodies must remain inspectable so the bridge can decide whether
        # a portable retry is appropriate.
        headers["Accept-Encoding"] = "identity"

        upstream_path = (upstream.path.rstrip("/") + "/" + self.path.lstrip("/")) or "/"
        if upstream.query:
            separator = "&" if "?" in upstream_path else "?"
            upstream_path += separator + upstream.query

        connection: http.client.HTTPConnection | None = None
        buffered_response: bytes | None = None
        portable_retry = False
        omitted_provider_items = 0
        try:
            request_headers = dict(headers)
            if body:
                request_headers["Content-Length"] = str(len(body))
            connection = http.client.HTTPConnection(upstream.hostname, upstream.port, timeout=600)
            connection.request(
                self.command,
                upstream_path,
                body=body or None,
                headers=request_headers,
            )
            response = connection.getresponse()

            # A rejected request has not produced a model response, so it is
            # safe to retry once after removing opaque provider state.
            if original_payload is not None and response.status == 400:
                first_error = response.read()
                if is_portability_error(response.status, first_error):
                    connection.close()
                    portable_payload, _, omitted_provider_items, _ = (
                        make_portable_responses_payload(original_payload)
                    )
                    portable_body = json.dumps(
                        portable_payload,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ).encode("utf-8")
                    retry_headers = dict(headers)
                    retry_headers["Content-Length"] = str(len(portable_body))
                    connection = http.client.HTTPConnection(
                        upstream.hostname,
                        upstream.port,
                        timeout=600,
                    )
                    connection.request(
                        self.command,
                        upstream_path,
                        body=portable_body,
                        headers=retry_headers,
                    )
                    response = connection.getresponse()
                    portable_retry = True
                else:
                    buffered_response = first_error

            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                lower = key.lower()
                if lower in HOP_BY_HOP or lower == "content-length":
                    continue
                self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()

            if buffered_response is not None:
                self.wfile.write(buffered_response)
                self.wfile.flush()
            else:
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            self.close_connection = True
            self.log_message(
                "%s %s -> %s; removed_item_ids=%d; "
                "model_override=%s; model_rewritten=%s; original_model=%s; "
                "cleared_reasoning_content=%d; "
                "removed_foreign_encrypted_content=%d; "
                "removed_previous_response_id=%s; "
                "portable_retry=%s; omitted_provider_items=%d",
                self.command,
                self.path,
                response.status,
                removed,
                self.server.model_override or "-",  # type: ignore[attr-defined]
                str(model_rewritten).lower(),
                original_model or "-",
                cleared_reasoning_content,
                removed_foreign_encrypted_content,
                str(previous_removed).lower(),
                str(portable_retry).lower(),
                omitted_provider_items,
            )
        except (OSError, http.client.HTTPException) as exc:
            self.send_error(502, f"CC Switch upstream error: {exc}")
        finally:
            if connection is not None:
                connection.close()

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_OPTIONS = _handle


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Adapt Codex Responses history across providers before forwarding "
            "to CC Switch."
        )
    )
    parser.add_argument("--listen", default="127.0.0.1:15722", help="listen host:port")
    parser.add_argument(
        "--upstream",
        default="http://127.0.0.1:15721",
        help="CC Switch proxy base URL",
    )
    parser.add_argument(
        "--model-override",
        default="",
        help=(
            "Optional official model to write into every JSON /responses "
            "replay request (for example gpt-5.6-sol)"
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    listen_host, listen_port_text = args.listen.rsplit(":", 1)
    upstream = urlsplit(args.upstream)
    if upstream.scheme != "http" or not upstream.hostname:
        raise SystemExit("--upstream must be an http:// URL")
    if upstream.port is None:
        upstream = urlsplit(f"http://{upstream.hostname}:80{upstream.path}")

    server = ThreadingHTTPServer((listen_host, int(listen_port_text)), BridgeHandler)
    server.upstream = upstream  # type: ignore[attr-defined]
    server.model_override = args.model_override.strip()  # type: ignore[attr-defined]

    def stop(_signum: int, _frame: object) -> None:
        # shutdown must run outside the signal handler's serve_forever frame.
        import threading

        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, stop)

    print(f"Codex bridge listening on http://{listen_host}:{listen_port_text}")
    print(f"Forwarding to {args.upstream}")
    if server.model_override:  # type: ignore[attr-defined]
        print(f"Rewriting request model to {server.model_override}")  # type: ignore[attr-defined]
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
