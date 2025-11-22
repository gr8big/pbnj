# PB&J: `duplex.py`

The `duplex` module offers a set of Quart-based PB&J managers.

## `duplex.QuartLongPollSessionManager`

An all-in-one session manager based on long-polling.

### `clean_session()`

Args:
- `ses: main.Session` - The session to clean.

Intended to be uses as a session close hook.

### `start_session()`

Start a session, opening a poll manager for it.

Returns: `pbnj.Session`

### `request_handler()`

A request handler for `POST` requests. This can be used directly as a Quart request handler.

The API then takes the following headers for authentication:
- `X-Pbj-Session-Id` - The ID of the session.
- `X-Pbj-Session` - The session token.

The request payload must be encoded using the following format:
- A 4-byte (32 bit) unsigned little-endian integer, denoting the number of incoming payloads
- For every payload:
    - A 4-byte (32 bit) unsigned little-endian integer, denoting the length of the payload
    - The payload itsself (see [main API docs](./api.md))

Returns an `AsyncIterable[bytes]` that can be returned as-is in a Quart request. It uses the same format as the request body.

### `push_handler()`

Similar to `request_handler()` but designed for `PUT` requests. This does not return any data, however, as it is simply for pushing additional messages.  
For the request format, see `request_handler()`. Headers and request body are identical.
