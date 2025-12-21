# Coleman

A high-performance log database implemented in Zig, leveraging gRPC and Protocol Buffers for communication.

Currently, it implements a simple in-memory key-value store with `Put` and `Get` operations, serving as a foundation for a columnar store log database.

## Prerequisites

- **Zig**: Version 0.15.2 or later.

## Building

To build the server and client executables:

```bash
zig build
```

This will create the executables in `zig-out/bin/`.

## Running

### Server

To start the gRPC server (listening on localhost:50051 by default):

```bash
zig build run
```

**Options:**

- `--limit <N>`: Shut down the server automatically after processing `N` requests. Useful for testing and benchmarking.

```bash
# Run server and stop after 2 requests
zig build run -- --limit 2
```

### Client

The client performs a simple test sequence: sending a `Put` request followed by a `Get` request.

```bash
./zig-out/bin/coleman-client
```

## Project Structure

- **`src/`**: Application source code.
  - **`main.zig`**: Entry point for the server application.
  - **`server.zig`**: Implementation of the gRPC server and request handlers (`handlePut`, `handleGet`).
  - **`client.zig`**: A simple gRPC client for testing the service.
  - **`proto/`**: Generated Zig code from Protocol Buffers definitions.
- **`proto/`**: Original `.proto` definitions (`log.proto`).
- **`libs/`**: Vendored dependencies.
  - **`gRPC-zig`**: gRPC implementation for Zig.
  - **`zig-protobuf`**: Protocol Buffers implementation for Zig.

## Development

### Regenerating Protocol Buffers

If you modify `proto/log.proto`, you need to regenerate the corresponding Zig code:

```bash
zig build gen-proto
```

### Dependencies

This project vendors `gRPC-zig` and `zig-protobuf` in the `libs/` directory. These libraries have been patched locally to ensure compatibility with Zig 0.15.2 (specifically regarding `std.io` interface changes and `std.compress`).

**Note**: Compression (gzip/deflate) is currently disabled in the transport layer due to changes in the Zig standard library's compression APIs.
