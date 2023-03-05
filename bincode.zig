const std = @import("std");

// TODO: special case deserialize for top level slice that only
// contains interior slices and input is a buffer, for a lazy
// zero allocation deserializer.

pub fn deserialize(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => try deserializeBool(stream),
        .Float => try deserializeFloat(stream, T),
        .Int => try deserializeInt(stream, T),
        .Optional => |info| try deserializeOptional(stream, allocator, info.child),
        .Pointer => |info| try deserializePointer(stream, info, allocator),
        .Array => |info| try deserializeArray(stream, info, allocator),
        .Struct => |info| try deserializeStruct(stream, info, allocator, T),
        .Enum => try deserializeEnum(stream, T),
        .Union => |info| try deserializeUnion(stream, info, allocator, T),
        else => unsupportedType(T),
    };
}

pub fn serialize(stream: anytype, value: anytype) @TypeOf(stream).Error!void {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .Void => {},
        .Bool => try serializeBool(stream, value),
        .Float => try serializeFloat(stream, T, value),
        .Int => try serializeInt(stream, T, value),
        .Optional => |info| try serializeOptional(stream, info.child, value),
        .Pointer => |info| try serializePointer(stream, info, T, value),
        .Array => |info| try serializeArray(stream, info, T, value),
        .Struct => |info| try serializeStruct(stream, info, T, value),
        .Enum => try serializeEnum(stream, T, value),
        .Union => |info| try serializeUnion(stream, info, T, value),
        else => unsupportedType(T),
    };
}

fn deserializeBool(stream: anytype) !bool {
    switch (try stream.readIntLittle(u8)) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    }
}

fn deserializeFloat(stream: anytype, comptime T: type) !T {
    switch (T) {
        f32 => return @bitCast(T, try stream.readIntLittle(u32)),
        f64 => return @bitCast(T, try stream.readIntLittle(u64)),
        else => unsupportedType(T),
    }
}

fn deserializeInt(stream: anytype, comptime T: type) !T {
    switch (T) {
        i8 => return try stream.readIntLittle(i8),
        i16 => return try stream.readIntLittle(i16),
        i32 => return try stream.readIntLittle(i32),
        i64 => return try stream.readIntLittle(i64),
        i128 => return try stream.readIntLittle(i128),
        u8 => return try stream.readIntLittle(u8),
        u16 => return try stream.readIntLittle(u16),
        u32 => return try stream.readIntLittle(u32),
        u64 => return try stream.readIntLittle(u64),
        u128 => return try stream.readIntLittle(u128),
        else => unsupportedType(T),
    }
}

fn deserializeOptional(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !?T {
    switch (try stream.readIntLittle(u8)) {
        // None
        0 => return null,
        // Some
        1 => return try deserialize(stream, allocator, T),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializePointer(stream: anytype, comptime info: std.builtin.Type.Pointer, allocator: std.mem.Allocator) ![]info.child {
    const T = @Type(.{ .Pointer = info });
    if (info.sentinel != null) unsupportedType(T);
    switch (info.size) {
        .One => unsupportedType(T),
        .Slice => {
            var len = @intCast(usize, try stream.readIntLittle(u64));
            var memory = try allocator.alloc(info.child, len);
            if (info.child == u8) {
                const amount = try stream.readAll(memory);
                if (amount != len) {
                    invalidProtocol("The stream end was found before all required bytes were read.");
                }
            } else {
                for (0..len) |idx| {
                    memory[idx] = try deserialize(stream, allocator, info.child);
                }
            }
            return memory;
        },
        .C => unsupportedType(T),
        .Many => unsupportedType(T),
    }
}

fn deserializeArray(stream: anytype, comptime info: std.builtin.Type.Array, allocator: std.mem.Allocator) ![info.len]info.child {
    const T = @Type(.{ .Array = info });
    if (info.sentinel != null) unsupportedType(T);
    var value: T = undefined;
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserialize(stream, allocator, info.child);
        }
    }
    return value;
}

fn deserializeStruct(stream: anytype, comptime info: std.builtin.Type.Struct, allocator: std.mem.Allocator, comptime T: type) !T {
    var value: T = undefined;
    inline for (info.fields) |field| {
        @field(value, field.name) = try deserialize(stream, allocator, field.type);
    }
    return value;
}

fn deserializeEnum(stream: anytype, comptime T: type) !T {
    const raw_tag = try deserializeInt(stream, u32);
    return @intToEnum(T, raw_tag);
}

fn deserializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, allocator: std.mem.Allocator, comptime T: type) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserialize(stream, allocator, u32);
        const tag = @intToEnum(Tag, raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                var inner = try deserialize(stream, allocator, field.type);
                return @unionInit(T, field.name, inner);
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

pub fn serializeBool(stream: anytype, value: bool) @TypeOf(stream).Error!void {
    const code: u8 = if (value) @as(u8, 1) else @as(u8, 0);
    return stream.writeIntLittle(u8, code);
}

pub fn serializeFloat(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (T) {
        f32 => try stream.writeIntLittle(u32, @bitCast(u32, value)),
        f64 => try stream.writeIntLittle(u64, @bitCast(u64, value)),
        else => unsupportedType(T),
    }
}

pub fn serializeInt(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (T) {
        i8 => try stream.writeIntLittle(i8, value),
        i16 => try stream.writeIntLittle(i16, value),
        i32 => try stream.writeIntLittle(i32, value),
        i64 => try stream.writeIntLittle(i64, value),
        i128 => try stream.writeIntLittle(i128, value),
        u8 => try stream.writeIntLittle(u8, value),
        u16 => try stream.writeIntLittle(u16, value),
        u32 => try stream.writeIntLittle(u32, value),
        u64 => try stream.writeIntLittle(u64, value),
        u128 => try stream.writeIntLittle(u128, value),
        else => unsupportedType(T),
    }
}

pub fn serializeOptional(stream: anytype, comptime T: type, value: ?T) @TypeOf(stream).Error!void {
    if (value) |actual| {
        try stream.writeIntLittle(u8, 1);
        try serialize(stream, actual);
    } else {
        // None
        try stream.writeIntLittle(u8, 0);
    }
}

pub fn serializePointer(stream: anytype, comptime info: std.builtin.Type.Pointer, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel != null) unsupportedType(T);
    switch (info.size) {
        .One => unsupportedType(T),
        .Slice => {
            try stream.writeIntLittle(u64, value.len);
            if (info.child == u8) {
                try stream.writeAll(value);
            } else {
                for (value) |item| {
                    try serialize(stream, item);
                }
            }
        },
        .C => unsupportedType(T),
        .Many => unsupportedType(T),
    }
}

pub fn serializeArray(stream: anytype, comptime info: std.builtin.Type.Array, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel != null) unsupportedType(T);
    if (info.child == u8) {
        try stream.writeAll(value);
    } else {
        for (value) |item| {
            try serialize(stream, item);
        }
    }
}

pub fn serializeStruct(stream: anytype, comptime info: std.builtin.Type.Struct, comptime T: type, value: T) @TypeOf(stream).Error!void {
    inline for (info.fields) |field| {
        try serialize(stream, @field(value, field.name));
    }
}

pub fn serializeEnum(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    const tag: u32 = @enumToInt(value);
    try serialize(stream, tag);
}

pub fn serializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.tag_type) |UnionTagType| {
        const tag: u32 = @enumToInt(value);
        try serialize(stream, tag);
        inline for (info.fields) |field| {
            if (value == @field(UnionTagType, field.name)) {
                try serialize(stream, @field(value, field.name));
            }
        }
    } else {
        unsupportedType(T);
    }
}

fn unsupportedType(comptime T: type) noreturn {
    @compileError("Unsupported type " ++ @typeName(T));
}

fn invalidProtocol(comptime message: []const u8) noreturn {
    @panic("Invalid protocol detected: " ++ message);
}

test "round trip" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    const expectEqual = std.testing.expectEqual;

    const examples = @import("rust/examples.zig");

    const TestUnion = union(enum) {
        x: i32,
        y: u32,
    };
    const TestEnum = enum {
        One,
        Two,
    };
    const TestType = struct {
        u: TestUnion,
        e: TestEnum,
        s: []const u8,
        point: [2]f64,
        o: ?u8,

        pub fn validate(self: @This(), other: @This()) !void {
            try expectEqual(self.u, other.u);
            try expectEqualStrings(self.s, other.s);
            try expectEqual(self.point, other.point);
            try expectEqual(self.o, other.o);
        }
    };

    const Integration = struct {
        fn validate(comptime T: type, value: T, expected: []const u8) !void {
            var buffer: [8192]u8 = undefined;

            // serialize value and make sure it matches exactly the bytes
            // from the rust implementation.
            var output_stream = std.io.fixedBufferStream(buffer[0..]);
            try serialize(output_stream.writer(), value);
            try std.testing.expectEqualSlices(u8, expected, output_stream.getWritten());

            // deserialize the bytes and make sure resulting object is exactly
            // what we started with.
            var input_stream = std.io.fixedBufferStream(expected);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var copy = try deserialize(input_stream.reader(), arena.allocator(), T);

            if (@typeInfo(T) == .Struct and @hasDecl(T, "validate")) {
                try T.validate(value, copy);
            } else {
                try std.testing.expectEqual(value, copy);
            }

            // NOTE: expectEqual does not do structural equality for slices.
        }
    };

    var testType = TestType{
        .u = .{ .y = 5 },
        .e = .One,
        .s = "abcdefgh",
        .point = .{ 1.1, 2.2 },
        .o = 255,
    };

    try Integration.validate(TestType, testType, examples.test_type);
    try Integration.validate(TestUnion, .{ .x = 6 }, examples.test_union);
    try Integration.validate(TestEnum, .Two, examples.test_enum);
    try Integration.validate(?u8, null, examples.none);
    try Integration.validate(i8, 100, examples.int_i8);
    try Integration.validate(u8, 101, examples.int_u8);
    try Integration.validate(i16, 102, examples.int_i16);
    try Integration.validate(u16, 103, examples.int_u16);
    try Integration.validate(i32, 104, examples.int_i32);
    try Integration.validate(u32, 105, examples.int_u32);
    try Integration.validate(i64, 106, examples.int_i64);
    try Integration.validate(u64, 107, examples.int_u64);
    try Integration.validate(i128, 108, examples.int_i128);
    try Integration.validate(u128, 109, examples.int_u128);
    try Integration.validate(f32, 5.5, examples.int_f32);
    try Integration.validate(f64, 6.6, examples.int_f64);
    try Integration.validate(bool, false, examples.bool_false);
    try Integration.validate(bool, true, examples.bool_true);
}

test "example" {
    const bincode = @This(); //@import("bincode-zig");

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
    const copy = try bincode.deserialize(
        input_stream.reader(),
        arena.allocator(),
        Shared,
    );

    // Make sure it is the same
    try std.testing.expectEqualStrings("Cat", copy.name);
    try std.testing.expectEqual(@as(u32, 5), copy.age);
}
