# PB&J Technical API Documentation

This document covers the specification for duplex communication and command handling.

## General Spec

Every message sent to and from the server must follow this specification:
- A 4-byte command ID
- The payload

To send a root message, the command ID must be set to 4,294,967,295 - i.e. `\xff\xff\xff\xff`. Therefore, all active commands must have an ID assigned between 0 and 4,294,967,294.

## Command Initiation & Lifetime

To start a command, an initiation frame must be sent. This frame must be a root message (command ID `\xff\xff\xff\xff`) sent with the following format:
- A 4-byte command ID - this is the ID that will be used to identify messages intended for this command. The provided ID must **not** be `\xff\xff\xff\xff`.
- A 1-byte length marker, defining length `n`
- A `n`-byte command type, which denotes the handler the client would like to initiate.

After a command has been initiated, any number of frames can be sent. Frames are a one-byte marker followed by the payload, where the marker denotes the type of frame. The following frame types are available:
- `00` - Null frames - Utterly useless.
- `40` - Binary frames - Sending of binary data.
- `41` - Text frames - Sending of string data as UTF-8 text.
- `50` - JSON frames - Sending of JSON-encoded objects.
- `ff` - EOF frame - See below.

At the end of a command's lifetime, an EOF frame is sent. The payload of this frame contains:
- A 1-byte status code
- A 1-byte length marker, defining length `n`
- A `n`-byte reason, which is UTF-8 text

The status is used as a broad success/failure indicator, where any status from `00` to `9f` is successful, and any status from `a0` to `ff` is a failure. The reason is a string in the format `provider:reason`, for example `pbj:command_not_exist` for PB&J's default "this command doesn't exist" error. The provider string in the reason may also be your reverse-DNS app ID, such as `org.billbot.cats`, to help prevent potential conflicts.  
The general method for rejecting a command is to use a standard status (see below) and a custom reason. Under no circumstances should a non-standard status code be used.

The following status codes are available:
- `0x00` - Generic OK - The command completed without issue.
- `0x10` - Partial - The command completed and a partial response was returned.
- `0x11` - Continue - The command completed and another command can now be used.
- `0x20` - Warning - The command completed but a warning is attached.
- `0x21` - No Content - The command completed without a response.

and the failure error codes:
- `0xa0` - Generic Failure - The command failed.
- `0xa1` - Not found - The requeted resource couldn't be found.
- `0xb0` - Unauthorized - The command couldn't be completed because the client is not authorized.
- `0xb1` - Bad Message - The client provided an invalid message.
- `0xb2` - Conflict - The command couldn't complete because it conflicts with the state of the server.
- `0xc0` - Time Out - The client didn't provide a required message in time.
