# bincode-zig
A zig binary serializer/deserializer that is compatible with the
rust [bincode](https://github.com/bincode-org/bincode) crate.

This is useful if you need to interoperate between zig and rust code.
For example, the [lunatic-zig](https://github.com/qbradley/lunatic-zig) module uses bincode to communicate
with the Sqlite api of the [lunatic](https://github.com/lunatic-solutions/lunatic) runtime.

## Package Reference

Add a bincode-zig to your build.zig.zon file

```zig
.{
    .dependencies = .{
        .@"bincode-zig" = .{
            .url = "https://github.com/qbradley/bincode-zig/archive/22f9347ed1a0d275fbd49c58d5e76859c31962fc.tar.gz",
            .hash = "12200f0952d5c962987e58dd204fa38d144af051f8aea76ba86d049265e6cad86430",
        }
    },
}
```

Then reference bincode-zig in your build.zig file

```zig
const bincode_zig = b.dependency("bincode-zig", .{
    .target = target,
    .optimize = optimize,
});

// Add module to executable
exe.addModule("bincode-zig", bincode_zig.module("bincode-zig"));
```

Finally, call the library from your code

```zig
test "example" {
    const bincode = @import("bincode-zig");

    const Shared = struct {
        name: []const u8,
        age: u32,
    };

    var example = Shared{ .name = "Cat", .age = 5 };

    // Serialize Shared to buffer
    var buffer: [8192]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(buffer[0..]);
    try bincode.serialize(output_stream.writer(), example);

    // Use an arena to gather allocations from deserializer to make
    // them easy to clean up together. Allocations are required for
    // slices.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Read what we wrote
    var input_stream = std.io.fixedBufferStream(output_stream.getWritten());
    const copy = try bincode.deserializeAlloc(
        input_stream.reader(),
        arena.allocator(),
        Shared,
    );

    // Make sure it is the same
    try std.testing.expectEqualStrings("Cat", copy.name);
    try std.testing.expectEqual(@as(u32, 5), copy.age);
}
```
