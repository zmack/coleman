# gRPC Method Routing Bug Fix

## Problem Description

When running the Coleman gRPC server and client, the following errors occurred:

```
debug(zig_protobuf): Unknown field received in .{ .wire_type = .len, .field = 2 }

error: BrokenPipe
/Users/zmack/.local/share/mise/installs/zig/0.15.2/lib/std/posix.zig:6188:26: 0x10307cd17 in sendmsg (coleman)
                .PIPE => return error.BrokenPipe,
                         ^
/Users/zmack/.local/share/mise/installs/zig/0.15.2/lib/std/net.zig:2300:21: 0x103077bdf in drain (coleman)
                    return error.WriteFailed;
                    ^
```

**Symptoms:**
- Server logged "Unknown field received" for field 2 when processing requests
- Server crashed with BrokenPipe error when trying to send responses
- Client would hang or fail to receive responses

## Root Cause Analysis

### Issue #1: Missing gRPC Method Routing

The server's `handleConnection` function ran **ALL handlers** for every incoming request:

```zig
// BROKEN CODE - from libs/gRPC-zig/src/server.zig
fn handleConnection(self: *GrpcServer, conn: std.net.Server.Connection) !void {
    // ...
    while (true) {
        const message = trans.readMessage() catch |err| { ... };
        defer self.allocator.free(message);

        // ❌ RUNS ALL HANDLERS FOR EVERY REQUEST!
        for (self.handlers.items) |handler| {
            self.requests_processed += 1;
            const response = try handler.handler_fn(message, self.allocator);
            defer self.allocator.free(response);
            try trans.writeMessage(response);
        }
    }
}
```

**What happened when a PUT request arrived:**

1. Client sent: `PutRequest { key: "test_key", value: "test_value" }`
   - Field 1 (key): "test_key"
   - Field 2 (value): "test_value"

2. Server ran `handlePut`:
   - ✅ Decoded as `PutRequest` successfully
   - ✅ Stored key-value pair
   - ✅ Sent success response

3. Server **ALSO** ran `handleGet` on the same PUT data:
   - ❌ Tried to decode as `GetRequest` (which only has field 1: key)
   - ❌ Encountered field 2 (value) → "Unknown field received"
   - ❌ Generated a response for GET
   - ❌ Tried to send second response

4. Client disconnected after receiving first response
5. Server tried to send second response → **BrokenPipe error**

### Issue #2: Missing HTTP/2 HEADERS Frame Support

The original implementation only sent/received DATA frames, not HEADERS frames:

```zig
// BROKEN CODE - from libs/gRPC-zig/src/transport.zig
pub fn readMessage(self: *Transport) ![]const u8 {
    while (true) {
        var frame = http2.frame.Frame.decode(self.stream, self.allocator) catch { ... };
        defer frame.deinit(self.allocator);

        if (frame.type == .DATA) {
            return try self.allocator.dupe(u8, frame.payload);
        }
        // ❌ Ignores HEADERS frames - no way to know which method was called!
    }
}
```

**Why this is a problem:**

In HTTP/2 (which gRPC uses), each request consists of:
- **HEADERS frame**: Contains metadata including the `:path` pseudo-header with the method name (e.g., "log.LogService/Put")
- **DATA frame**: Contains the actual protobuf-encoded message body

Without reading HEADERS, the server had no way to route requests to the correct handler!

### Issue #3: HTTP/2 Frame Mismatch

**Client behavior:**
- Sent only DATA frames (no HEADERS)

**Server expectation after fix:**
- Expected both HEADERS and DATA frames

**Result:**
- Server hung waiting for HEADERS that never came
- Client hung waiting for response that was never sent

## gRPC and HTTP/2 Background

### How gRPC Works

gRPC uses HTTP/2 as its transport protocol. Each gRPC call follows this structure:

```
Client Request:
┌─────────────────────────────────────┐
│ HEADERS Frame                       │
│  :method = POST                     │
│  :scheme = http                     │
│  :path = /log.LogService/Put  ◄──── Method name here!
│  content-type = application/grpc    │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│ DATA Frame                          │
│  [Protobuf-encoded PutRequest]      │
└─────────────────────────────────────┘

Server Response:
┌─────────────────────────────────────┐
│ HEADERS Frame                       │
│  :status = 200                      │
│  content-type = application/grpc    │
└─────────────────────────────────────┘
┌─────────────────────────────────────┐
│ DATA Frame                          │
│  [Protobuf-encoded PutResponse]     │
└─────────────────────────────────────┘
```

### HPACK Header Compression

HTTP/2 uses HPACK to compress headers. The `:path` header containing the method name is encoded as:

```
Before HPACK encoding:
{
  ":path": "log.LogService/Put"
}

After HPACK encoding:
[0x0, 0x5, ':', 'p', 'a', 't', 'h', 0x18, 'l', 'o', 'g', '.', 'L', 'o', 'g', 'S', 'e', 'r', 'v', 'i', 'c', 'e', '/', 'P', 'u', 't']
(26 bytes)
```

## The Fix

### Part 1: Capture HTTP/2 HEADERS Frames

Modified `Transport` to capture both HEADERS and DATA frames and extract the method name:

```zig
// libs/gRPC-zig/src/transport.zig

// New struct to hold both method and data
pub const Message = struct {
    method: []const u8,  // gRPC method path (e.g., "log.LogService/Put")
    data: []const u8,    // Protobuf message data
};

pub const Transport = struct {
    stream: net.Stream,
    allocator: std.mem.Allocator,
    http2_conn: ?http2.connection.Connection,
    hpack_decoder: http2.hpack.Decoder,  // ← Added for header decoding

    pub fn readMessage(self: *Transport) !Message {
        var method: ?[]const u8 = null;
        var data: ?[]const u8 = null;

        // Read frames until we have both headers and data
        while (method == null or data == null) {
            var frame = http2.frame.Frame.decode(self.stream, self.allocator) catch |err| {
                if (err == error.EndOfStream) return TransportError.ConnectionClosed;
                return err;
            };
            defer frame.deinit(self.allocator);

            switch (frame.type) {
                .HEADERS => {
                    // Decode HPACK headers
                    var headers = try self.hpack_decoder.decode(frame.payload);
                    defer {
                        // Free all header keys and values (prevent memory leak)
                        var it = headers.iterator();
                        while (it.next()) |entry| {
                            self.allocator.free(entry.key_ptr.*);
                            self.allocator.free(entry.value_ptr.*);
                        }
                        headers.deinit();
                    }

                    // Extract :path pseudo-header (contains the method name)
                    if (headers.get(":path")) |path| {
                        method = try self.allocator.dupe(u8, path);
                    }
                },
                .DATA => {
                    data = try self.allocator.dupe(u8, frame.payload);
                },
                else => {
                    // Ignore other frame types (SETTINGS, etc.)
                    continue;
                },
            }
        }

        return Message{
            .method = method.?,
            .data = data.?,
        };
    }
};
```

**Key changes:**
- Returns `Message` struct instead of just `[]const u8`
- Captures HEADERS frame and decodes HPACK encoding
- Extracts `:path` header containing the method name
- Properly frees allocated header strings to prevent memory leaks

### Part 2: Implement Proper Method Routing

Updated the server to route based on method name:

```zig
// libs/gRPC-zig/src/server.zig

fn handleConnection(self: *GrpcServer, conn: std.net.Server.Connection) !void {
    var trans = try transport.Transport.init(self.allocator, conn.stream, true);
    defer trans.deinit();

    while (true) {
        const message = trans.readMessage() catch |err| switch (err) {
            error.ConnectionClosed => break,
            else => return err,
        };

        defer self.allocator.free(message.method);
        defer self.allocator.free(message.data);

        // Find the matching handler for this method
        var handler_found = false;
        for (self.handlers.items) |handler| {
            if (std.mem.eql(u8, handler.name, message.method)) {
                handler_found = true;
                self.requests_processed += 1;
                const response = try handler.handler_fn(message.data, self.allocator);
                defer self.allocator.free(response);

                // Send response with method path in headers
                try trans.writeRequest(message.method, response);
                break;  // ← Only call ONE handler!
            }
        }

        if (!handler_found) {
            std.log.warn("No handler found for method: {s}", .{message.method});
        }
    }
}
```

**Key changes:**
- Compare `handler.name` with `message.method` to find the right handler
- Only call the matching handler (not all handlers)
- Pass `message.data` (not the full message) to handler functions
- Break after finding and calling the correct handler

### Part 3: Send HEADERS Frames from Client

Added `writeRequest` method to send both HEADERS and DATA frames:

```zig
// libs/gRPC-zig/src/transport.zig

pub fn writeRequest(self: *Transport, method: []const u8, data: []const u8) !void {
    // Create HPACK encoder for headers
    var encoder = try http2.hpack.Encoder.init(self.allocator);
    defer encoder.deinit();

    // Build headers with :path pseudo-header
    var headers = std.StringHashMap([]const u8).init(self.allocator);
    defer headers.deinit();
    try headers.put(":path", method);

    // Encode headers using HPACK
    const encoded_headers = try encoder.encode(headers);
    defer self.allocator.free(encoded_headers);

    // Send HEADERS frame
    var headers_frame = http2.frame.Frame{
        .length = @intCast(encoded_headers.len),
        .type = .HEADERS,
        .flags = http2.frame.FrameFlags.END_HEADERS,
        .stream_id = 1,
        .payload = encoded_headers,
    };
    try headers_frame.encode(self.stream);

    // Send DATA frame
    var data_frame = http2.frame.Frame{
        .length = @intCast(data.len),
        .type = .DATA,
        .flags = http2.frame.FrameFlags.END_STREAM,
        .stream_id = 1,
        .payload = data,
    };
    try data_frame.encode(self.stream);
}
```

Updated client to use `writeRequest`:

```zig
// libs/gRPC-zig/src/client.zig

pub fn call(self: *GrpcClient, method: []const u8, request: []const u8, compression_alg: compression.Compression.Algorithm) ![]u8 {
    // ... compression code ...

    // Send request with HEADERS + DATA frames
    try self.transport.writeRequest(method, compressed);

    // Read response (HEADERS + DATA frames)
    const message = try self.transport.readMessage();
    defer self.allocator.free(message.method);
    defer self.allocator.free(message.data);

    // Decompress response
    return self.compression.decompress(message.data, compression_alg);
}
```

## Message Flow (After Fix)

```
Client                          Server
  │                               │
  │──── HEADERS (:path=/Put) ────▶│
  │──── DATA (PutRequest) ────────▶│
  │                               │ 1. readMessage() captures both frames
  │                               │ 2. Extracts method: "log.LogService/Put"
  │                               │ 3. Routes to handlePut (only!)
  │                               │ 4. Processes PUT request
  │                               │ 5. Generates response
  │                               │
  │◀──── HEADERS (:path=/Put) ────│
  │◀──── DATA (PutResponse) ──────│
  │                               │
  │ 6. readMessage() captures response
  │ 7. Returns PutResponse data
  │                               │
  │──── HEADERS (:path=/Get) ────▶│
  │──── DATA (GetRequest) ────────▶│
  │                               │ 8. Routes to handleGet (only!)
  │                               │ 9. Processes GET request
  │                               │
  │◀──── HEADERS (:path=/Get) ────│
  │◀──── DATA (GetResponse) ──────│
  │                               │
```

## Testing & Verification

### Test Output

```bash
$ ./zig-out/bin/coleman &
$ ./zig-out/bin/coleman-client

Starting Log Service...
info: Server listening on 127.0.0.1:50051
info: New connection from 127.0.0.1:xxxxx

# First request (PUT)
debug: Sending HEADERS frame: method=log.LogService/Put, encoded_len=26
debug: Sending DATA frame: length=22
debug: Received frame type: HEADERS, length: 26
debug: Processing HEADERS frame
debug: Extracted method: log.LogService/Put
debug: Received frame type: DATA, length: 22
debug: Processing DATA frame
Put response: success=true

# Second request (GET)
debug: Sending HEADERS frame: method=log.LogService/Get, encoded_len=26
debug: Sending DATA frame: length=10
debug: Received frame type: HEADERS, length: 26
debug: Processing HEADERS frame
debug: Extracted method: log.LogService/Get
debug: Received frame type: DATA, length: 10
debug: Processing DATA frame
Get response: found=true, value=test_value

debug: Waiting for message...
info: Connection closed
```

### Results

✅ **Both PUT and GET operations work correctly**
- PUT stores key-value pair and returns success
- GET retrieves stored value

✅ **No "Unknown field" errors**
- Each handler only processes its own request type
- No cross-contamination between PutRequest and GetRequest

✅ **No BrokenPipe errors**
- Server sends exactly one response per request
- Client receives response before disconnecting

✅ **Zero memory leaks**
- HPACK header strings properly freed
- GPA leak detection reports no leaks

✅ **Proper HTTP/2 frame handling**
- Both HEADERS and DATA frames sent/received
- Method routing based on `:path` header

## Files Modified

1. `libs/gRPC-zig/src/transport.zig`
   - Added `Message` struct
   - Modified `readMessage()` to capture HEADERS and DATA
   - Added `writeRequest()` to send HEADERS and DATA
   - Added HPACK decoder to Transport struct
   - Fixed memory leaks in header handling

2. `libs/gRPC-zig/src/server.zig`
   - Implemented method-based routing
   - Only call matching handler
   - Use `writeRequest()` for responses

3. `libs/gRPC-zig/src/client.zig`
   - Use `writeRequest()` instead of `writeMessage()`
   - Handle `Message` struct from `readMessage()`

## Technical Lessons

### 1. gRPC Requires HTTP/2 HEADERS

gRPC is not just protobuf over TCP. It requires proper HTTP/2 framing with HEADERS to identify methods. The `:path` pseudo-header is critical for routing.

### 2. All Handlers Running = Anti-Pattern

Running all handlers for every request is fundamentally broken:
- Wrong handlers process wrong data types → decode errors
- Multiple responses sent per request → protocol violations
- Client gets confused or disconnects → connection errors

### 3. HPACK Decoder Memory Management

HPACK decoders allocate strings for header names and values. These must be manually freed because `StringHashMap.deinit()` only frees the hashmap structure, not the contents.

### 4. HTTP/2 Frame Symmetry

Both requests and responses need the same frame structure:
- HEADERS frame (method/status information)
- DATA frame (message body)

Asymmetry causes hangs because one side waits for frames the other never sends.

### 5. Zig's Explicit Memory Management Pays Off

The GPA leak detector immediately identified the HPACK memory leak, allowing us to fix it before it became a production issue. This would be harder to catch in garbage-collected languages.

## Comparison with Other Languages

### Go (official gRPC implementation)

```go
// Go handles all of this automatically
type server struct {
    pb.UnimplementedLogServiceServer
}

func (s *server) Put(ctx context.Context, req *pb.PutRequest) (*pb.PutResponse, error) {
    // Method routing handled by gRPC framework
    // HTTP/2 framing handled automatically
    return &pb.PutResponse{Success: true}, nil
}
```

Go's gRPC library abstracts away HTTP/2 details completely. The framework:
- Automatically reads HEADERS to determine which method to call
- Routes to the correct handler via reflection
- Manages all frame encoding/decoding

### Rust (tonic framework)

```rust
#[tonic::async_trait]
impl LogService for MyLogService {
    async fn put(&self, req: Request<PutRequest>) -> Result<Response<PutResponse>, Status> {
        // tonic handles HTTP/2 and routing
        Ok(Response::new(PutResponse { success: true }))
    }
}
```

Rust's tonic framework (built on tokio and hyper):
- Uses macros to generate routing code
- HTTP/2 handling via hyper library
- Type-safe method routing at compile time

### Zig (our implementation)

```zig
// We had to implement HTTP/2 and routing manually
fn handlePut(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Manually decode protobuf
    // Manually encode response
    // Framework does HTTP/2 framing and routing
}
```

Zig requires explicit implementation of:
- HTTP/2 frame reading/writing
- HPACK header encoding/decoding
- Method routing logic
- Memory management for all allocated data

**Tradeoff:** More code but complete control and understanding of the protocol.

## Future Improvements

1. **Stream ID Management**: Currently hardcoded to stream ID 1. Should increment for each request.

2. **Full HTTP/2 Headers**: Only sending `:path`. Should include `:method`, `:scheme`, `content-type`, etc.

3. **SETTINGS Frame Acknowledgment**: Should properly ACK SETTINGS frames instead of ignoring them.

4. **Error Responses**: Currently only success/failure. Should support gRPC status codes (OK, INVALID_ARGUMENT, NOT_FOUND, etc.).

5. **Streaming**: Only supports unary calls. gRPC also supports:
   - Server streaming
   - Client streaming
   - Bidirectional streaming

6. **Connection Pooling**: Currently one request per connection. Should reuse connections.

7. **Metadata/Context**: gRPC supports arbitrary metadata in headers for tracing, auth, etc.

## Conclusion

This bug demonstrated the importance of understanding transport protocols when implementing RPC systems. What appeared as a "field mismatch" error was actually:

1. Missing method routing (architectural issue)
2. Missing HTTP/2 HEADERS support (protocol issue)
3. Frame asymmetry between client and server (integration issue)

The fix required understanding:
- How gRPC uses HTTP/2
- How HTTP/2 multiplexes requests via HEADERS frames
- How HPACK compresses headers
- How to properly manage memory in Zig

The Coleman project now has a **working, leak-free gRPC implementation** that properly routes requests and handles HTTP/2 framing!
