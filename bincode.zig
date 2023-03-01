const std = @import("std");

pub fn deserialize(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    switch (@typeInfo(T)) {
        .Void => {},
        .Bool => switch (try stream.readIntLittle(u8)) {
            0 => return false,
            1 => return true,
            else => unreachable,
        },
        .Float => switch (T) {
            f32 => return @bitCast(T, try stream.readIntLittle(u32)),
            f64 => return @bitCast(T, try stream.readIntLittle(u64)),
            else => unsupportedType(T),
        },
        .Int => switch (T) {
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
        },
        .Optional => |opt| switch (try stream.readIntLittle(u8)) {
            // None
            0 => return null,
            // Some
            1 => return try deserialize(stream, allocator, opt.child),
            else => unreachable,
        },
        .Pointer => |ptr| {
            if (ptr.sentinel != null) unsupportedType(T);
            switch (ptr.size) {
                .One => unsupportedType(T),
                .Slice => {
                    var len = @intCast(usize, try stream.readIntLittle(u64));
                    var memory = try allocator.alloc(ptr.child, len);
                    if (ptr.child == u8) {
                        const amount = try stream.readAll(memory);
                        if (amount != len) {
                            unreachable;
                        }
                    } else {
                        for (0..len) |idx| {
                            memory[idx] = try deserialize(stream, allocator, ptr.child);
                        }
                    }
                    return memory;
                },
                .C => unsupportedType(T),
                .Many => unsupportedType(T),
            }
        },
        .Array => |arr| {
            if (arr.sentinel != null) unsupportedType(T);
            var value: T = undefined;
            if (arr.child == u8) {
                const amount = try stream.readAll(value[0..]);
                if (amount != arr.len) {
                    unreachable;
                }
            } else {
                for (0..arr.len) |idx| {
                    value[idx] = try deserialize(stream, allocator, arr.child);
                }
            }
            return value;
        },
        .Struct => |info| {
            var value: T = undefined;
            inline for (info.fields) |field| {
                @field(value, field.name) = try deserialize(stream, allocator, field.type);
            }
            return value;
        },
        .Enum => {
            const raw_tag = try deserialize(stream, allocator, u32);
            return @intToEnum(T, raw_tag);
        },
        .Union => |info| {
            if (info.tag_type) |Tag| {
                const raw_tag = try deserialize(stream, allocator, u32);
                const tag = @intToEnum(Tag, raw_tag);

                inline for (info.fields) |field| {
                    if (tag == @field(Tag, field.name)) {
                        var inner = try deserialize(stream, allocator, field.type);
                        return @unionInit(T, field.name, inner);
                    }
                }
            } else {
                unsupportedType(T);
            }
        },
        else => unsupportedType(T),
    }
    unreachable;
}

pub fn serialize(stream: anytype, value: anytype) @TypeOf(stream).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Void => return,
        .Bool => try stream.writeIntLittle(u8, if (value) @as(u8, 1) else @as(u8, 0)),
        .Float => switch (T) {
            f32 => try stream.writeIntLittle(u32, @bitCast(u32, value)),
            f64 => try stream.writeIntLittle(u64, @bitCast(u64, value)),
            else => unsupportedType(T),
        },
        .Int => switch (T) {
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
        },
        .Optional => {
            if (value) |actual| {
                try stream.writeIntLittle(u8, 1);
                try serialize(stream, actual);
            } else {
                // None
                try stream.writeIntLittle(u8, 0);
            }
        },
        .Pointer => |ptr| {
            if (ptr.sentinel != null) unsupportedType(T);
            switch (ptr.size) {
                .One => unsupportedType(T),
                .Slice => {
                    try stream.writeIntLittle(u64, value.len);
                    if (ptr.child == u8) {
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
        },
        .Array => |arr| {
            if (arr.sentinel != null) unsupportedType(T);
            if (arr.child == u8) {
                try stream.writeAll(value);
            } else {
                for (value) |item| {
                    try serialize(stream, item);
                }
            }
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                try serialize(stream, @field(value, field.name));
            }
        },
        .Enum => {
            const tag: u32 = @enumToInt(value);
            try serialize(stream, tag);
        },
        .Union => |info| {
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
        },
        else => unsupportedType(T),
    }
}

fn unsupportedType(comptime T: type) void {
    @compileError("Unsupported type " ++ @typeName(T));
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
