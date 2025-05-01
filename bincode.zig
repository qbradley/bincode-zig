const std = @import("std");

pub fn deserializeAlloc(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => try deserializeBool(stream),
        .float => try deserializeFloat(stream, T),
        .int => try deserializeInt(stream, T),
        .optional => |info| try deserializeOptionalAlloc(stream, allocator, info.child),
        .pointer => |info| try deserializePointerAlloc(stream, info, allocator),
        .array => |info| try deserializeArrayAlloc(stream, info, allocator),
        .@"struct" => |info| try deserializeStructAlloc(stream, info, allocator, T),
        .@"enum" => try deserializeEnum(stream, T),
        .@"union" => |info| try deserializeUnionAlloc(stream, info, allocator, T),
        else => unsupportedType(T),
    };
}

pub fn deserialize(stream: anytype, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => try deserializeBool(stream),
        .float => try deserializeFloat(stream, T),
        .int => try deserializeInt(stream, T),
        .optional => |info| try deserializeOptional(stream, info.child),
        .array => |info| try deserializeArray(stream, info),
        .@"struct" => |info| try deserializeStruct(stream, info, T),
        .@"enum" => try deserializeEnum(stream, T),
        .@"union" => |info| try deserializeUnion(stream, info, T),
        else => unsupportedType(T),
    };
}

pub fn deserializeBuffer(comptime T: type, source: *[]const u8) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => deserializeBufferBool(source),
        .float => deserializeBufferFloat(T, source),
        .int => deserializeBufferInt(T, source),
        .optional => |info| deserializeBufferOptional(info.child, source),
        .pointer => |info| deserializeBufferPointer(info, source),
        .array => |info| deserializeBufferArray(info, source),
        .@"struct" => |info| deserializeBufferStruct(T, info, source),
        .@"enum" => deserializeBufferEnum(T, source),
        .@"union" => |info| deserializeBufferUnion(T, info, source),
        else => unsupportedType(T),
    };
}

pub fn serialize(stream: anytype, value: anytype) @TypeOf(stream).Error!void {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => try serializeBool(stream, value),
        .float => try serializeFloat(stream, T, value),
        .int => try serializeInt(stream, T, value),
        .optional => |info| try serializeOptional(stream, info.child, value),
        .pointer => |info| try serializePointer(stream, info, T, value),
        .array => |info| try serializeArray(stream, info, T, value),
        .@"struct" => |info| try serializeStruct(stream, info, T, value),
        .@"enum" => try serializeEnum(stream, T, value),
        .@"union" => |info| try serializeUnion(stream, info, T, value),
        else => unsupportedType(T),
    };
}

pub fn deserializeSliceIterator(comptime T: type, source: []const u8) DeserializeSliceIterator(T) {
    return DeserializeSliceIterator(T){
        .source = source,
    };
}

pub fn DeserializeSliceIterator(comptime T: type) type {
    return struct {
        source: []const u8,

        pub fn next(self: *@This()) ?T {
            if (self.source.len > 0) {
                return deserializeBuffer(T, &self.source);
            } else {
                return null;
            }
        }
    };
}

fn deserializeBufferInt(comptime T: type, source_ptr: *[]const u8) T {
    const bytesRequired = @sizeOf(T);
    const source = source_ptr.*;
    if (bytesRequired <= source.len) {
        var tmp: [bytesRequired]u8 = undefined;
        std.mem.copyForwards(u8, &tmp, source[0..bytesRequired]);
        source_ptr.* = source[bytesRequired..];
        return std.mem.readInt(T, &tmp, .little);
    } else {
        invalidProtocol("Buffer ran out of bytes too soon.");
    }
}

fn deserializeBufferBool(source: *[]const u8) bool {
    return switch (deserializeBufferInt(u8, source)) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    };
}

fn deserializeBufferOptional(comptime T: type, source: *[]const u8) ?T {
    if (deserializeBufferBool(source)) {
        return deserializeBuffer(T, source);
    } else {
        return null;
    }
}

fn deserializeBufferFloat(comptime T: type, source: *[]const u8) T {
    switch (T) {
        f32 => return @bitCast(deserializeBufferInt(u32, source)),
        f64 => return @bitCast(deserializeBufferInt(u64, source)),
        else => unsupportedType(T),
    }
}

fn deserializeBufferEnum(comptime T: type, source: *[]const u8) T {
    const raw_tag = deserializeBufferInt(u32, source);
    return @enumFromInt(raw_tag);
}

fn deserializeBufferStruct(comptime T: type, comptime info: std.builtin.Type.Struct, source: *[]const u8) T {
    var value: T = undefined;
    inline for (info.fields) |field| {
        @field(value, field.name) = deserializeBuffer(field.type, source);
    }
    return value;
}

fn deserializeBufferUnion(comptime T: type, comptime info: std.builtin.Type.Union, source: *[]const u8) T {
    if (info.tag_type) |Tag| {
        const raw_tag = deserializeBufferInt(u32, source);
        const tag: Tag = @enumFromInt(raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = deserializeBuffer(field.type, source);
                return @unionInit(T, field.name, inner);
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

fn deserializeBufferArray(comptime info: std.builtin.Type.Array, source_ptr: *[]const u8) [info.len]info.child {
    const T = @Type(.{ .array = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    var value: T = undefined;
    if (info.child == u8) {
        const source = source_ptr.*;
        if (info.len <= source.len) {
            std.mem.copyForwards(u8, &value, source[0..info.len]);
            source_ptr.* = source[info.len..];
        } else {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = deserializeBuffer(info.child, source_ptr);
        }
    }
    return value;
}

fn deserializeBufferPointer(comptime info: std.builtin.Type.Pointer, source_ptr: *[]const u8) []const info.child {
    const T = @Type(.{ .pointer = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    switch (info.size) {
        .one => unsupportedType(T),
        .slice => {
            const len: usize = @intCast(deserializeBufferInt(u64, source_ptr));
            if (info.child == u8) {
                const source = source_ptr.*;
                if (len <= source.len) {
                    source_ptr.* = source[len..];
                    return source[0..len];
                } else {
                    invalidProtocol("The stream end was found before all required bytes were read.");
                }
            } else {
                // we can't support a variable slice of types where the stream format
                // differs from in-memory format without allocating.
                unsupportedType(T);
            }
        },
        .c => unsupportedType(T),
        .many => unsupportedType(T),
    }
}

fn deserializeBool(stream: anytype) !bool {
    switch (try stream.readInt(u8, .little)) {
        0 => return false,
        1 => return true,
        else => invalidProtocol("Boolean values should be encoded as a single byte with value 0 or 1 only."),
    }
}

fn deserializeFloat(stream: anytype, comptime T: type) !T {
    switch (T) {
        f32 => return @bitCast(try stream.readInt(u32, .little)),
        f64 => return @bitCast(try stream.readInt(u64, .little)),
        else => unsupportedType(T),
    }
}

fn deserializeInt(stream: anytype, comptime T: type) !T {
    switch (T) {
        i8 => return try stream.readInt(i8, .little),
        i16 => return try stream.readInt(i16, .little),
        i32 => return try stream.readInt(i32, .little),
        i64 => return try stream.readInt(i64, .little),
        i128 => return try stream.readInt(i128, .little),
        u8 => return try stream.readInt(u8, .little),
        u16 => return try stream.readInt(u16, .little),
        u32 => return try stream.readInt(u32, .little),
        u64 => return try stream.readInt(u64, .little),
        u128 => return try stream.readInt(u128, .little),
        else => unsupportedType(T),
    }
}

fn deserializeOptionalAlloc(stream: anytype, allocator: std.mem.Allocator, comptime T: type) !?T {
    switch (try stream.readInt(u8, .little)) {
        // None
        0 => return null,
        // Some
        1 => return try deserializeAlloc(stream, allocator, T),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializeOptional(stream: anytype, comptime T: type) !?T {
    switch (try stream.readInt(u8, .little)) {
        // None
        0 => return null,
        // Some
        1 => return try deserialize(stream, T),
        else => invalidProtocol("Optional is encoded as a single 0 valued byte for null, or a single 1 valued byte followed by the encoding of the contained value."),
    }
}

fn deserializePointerAlloc(stream: anytype, comptime info: std.builtin.Type.Pointer, allocator: std.mem.Allocator) ![]info.child {
    const T = @Type(.{ .pointer = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    switch (info.size) {
        .one => unsupportedType(T),
        .slice => {
            const len: usize = @intCast(try stream.readInt(u64, .little));
            var memory = try allocator.alloc(info.child, len);
            if (info.child == u8) {
                const amount = try stream.readAll(memory);
                if (amount != len) {
                    invalidProtocol("The stream end was found before all required bytes were read.");
                }
            } else {
                for (0..len) |idx| {
                    memory[idx] = try deserializeAlloc(stream, allocator, info.child);
                }
            }
            return memory;
        },
        .c => unsupportedType(T),
        .many => unsupportedType(T),
    }
}

fn deserializeArrayAlloc(stream: anytype, comptime info: std.builtin.Type.Array, allocator: std.mem.Allocator) ![info.len]info.child {
    const T = @Type(.{ .array = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    var value: T = undefined;
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserializeAlloc(stream, allocator, info.child);
        }
    }
    return value;
}

fn deserializeArray(stream: anytype, comptime info: std.builtin.Type.Array) ![info.len]info.child {
    const T = @Type(.{ .array = info });
    if (info.sentinel_ptr != null) unsupportedType(T);
    var value: T = undefined;
    if (info.child == u8) {
        const amount = try stream.readAll(value[0..]);
        if (amount != info.len) {
            invalidProtocol("The stream end was found before all required bytes were read.");
        }
    } else {
        for (0..info.len) |idx| {
            value[idx] = try deserialize(stream, info.child);
        }
    }
    return value;
}

fn deserializeStructAlloc(stream: anytype, comptime info: std.builtin.Type.Struct, allocator: std.mem.Allocator, comptime T: type) !T {
    var value: T = undefined;
    inline for (info.fields) |field| {
        @field(value, field.name) = try deserializeAlloc(stream, allocator, field.type);
    }
    return value;
}

fn deserializeStruct(stream: anytype, comptime info: std.builtin.Type.Struct, comptime T: type) !T {
    var value: T = undefined;
    inline for (info.fields) |field| {
        @field(value, field.name) = try deserialize(stream, field.type);
    }
    return value;
}

fn deserializeEnum(stream: anytype, comptime T: type) !T {
    const raw_tag = try deserializeInt(stream, u32);
    return @enumFromInt(raw_tag);
}

fn deserializeUnionAlloc(stream: anytype, comptime info: std.builtin.Type.Union, allocator: std.mem.Allocator, comptime T: type) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserializeAlloc(stream, allocator, u32);
        const tag: Tag = @enumFromInt(raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = try deserializeAlloc(stream, allocator, field.type);
                return @unionInit(T, field.name, inner);
            }
        }
        unreachable;
    } else {
        unsupportedType(T);
    }
}

fn deserializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, comptime T: type) !T {
    if (info.tag_type) |Tag| {
        const raw_tag = try deserialize(stream, u32);
        const tag: Tag = @enumFromInt(raw_tag);

        inline for (info.fields) |field| {
            if (tag == @field(Tag, field.name)) {
                const inner = try deserialize(stream, field.type);
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
    return stream.writeInt(u8, code, .little);
}

pub fn serializeFloat(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (T) {
        f32 => try stream.writeInt(u32, @bitCast(value), .little),
        f64 => try stream.writeInt(u64, @bitCast(value), .little),
        else => unsupportedType(T),
    }
}

pub fn serializeInt(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (T) {
        i8 => try stream.writeInt(i8, value, .little),
        i16 => try stream.writeInt(i16, value, .little),
        i32 => try stream.writeInt(i32, value, .little),
        i64 => try stream.writeInt(i64, value, .little),
        i128 => try stream.writeInt(i128, value, .little),
        u8 => try stream.writeInt(u8, value, .little),
        u16 => try stream.writeInt(u16, value, .little),
        u32 => try stream.writeInt(u32, value, .little),
        u64 => try stream.writeInt(u64, value, .little),
        u128 => try stream.writeInt(u128, value, .little),
        else => unsupportedType(T),
    }
}

pub fn serializeOptional(stream: anytype, comptime T: type, value: ?T) @TypeOf(stream).Error!void {
    if (value) |actual| {
        try stream.writeInt(u8, 1, .little);
        try serialize(stream, actual);
    } else {
        // None
        try stream.writeInt(u8, 0, .little);
    }
}

pub fn serializePointer(stream: anytype, comptime info: std.builtin.Type.Pointer, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel_ptr != null) unsupportedType(T);
    switch (info.size) {
        .one => unsupportedType(T),
        .slice => {
            try stream.writeInt(u64, value.len, .little);
            if (info.child == u8) {
                try stream.writeAll(value);
            } else {
                for (value) |item| {
                    try serialize(stream, item);
                }
            }
        },
        .c => unsupportedType(T),
        .many => unsupportedType(T),
    }
}

pub fn serializeArray(stream: anytype, comptime info: std.builtin.Type.Array, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.sentinel_ptr != null) unsupportedType(T);
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
    const tag: u32 = @intFromEnum(value);
    try serialize(stream, tag);
}

pub fn serializeUnion(stream: anytype, comptime info: std.builtin.Type.Union, comptime T: type, value: T) @TypeOf(stream).Error!void {
    if (info.tag_type) |UnionTagType| {
        const tag: u32 = @intFromEnum(value);
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
    const TestTypeAlloc = struct {
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

    const TestType = struct {
        u: TestUnion,
        e: TestEnum,
        point: [2]f64,
        o: ?u8,

        pub fn validate(self: @This(), other: @This()) !void {
            try expectEqual(self.u, other.u);
            try expectEqual(self.point, other.point);
            try expectEqual(self.o, other.o);
        }
    };

    const Integration = struct {
        fn validateAlloc(comptime T: type, value: T, expected: []const u8) !void {
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
            const copy = try deserializeAlloc(input_stream.reader(), arena.allocator(), T);

            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) {
                try T.validate(value, copy);
            } else {
                try std.testing.expectEqual(value, copy);
            }

            // NOTE: expectEqual does not do structural equality for slices.
        }
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
            const copy = try deserialize(input_stream.reader(), T);

            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) {
                try T.validate(value, copy);
            } else {
                try std.testing.expectEqual(value, copy);
            }

            // NOTE: expectEqual does not do structural equality for slices.
        }

        fn validateBuffer(comptime T: type, value: T, expected: []const u8) !void {
            var buffer: [8192]u8 = undefined;

            // serialize value and make sure it matches exactly the bytes
            // from the rust implementation.
            var output_stream = std.io.fixedBufferStream(buffer[0..]);
            try serialize(output_stream.writer(), value);
            try std.testing.expectEqualSlices(u8, expected, output_stream.getWritten());

            // deserialize the bytes and make sure resulting object is exactly
            // what we started with.
            var input_stream: []const u8 = expected;
            const copy = deserializeBuffer(T, &input_stream);
            try expectEqual(@as(usize, 0), input_stream.len);

            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "validate")) {
                try T.validate(value, copy);
            } else {
                try std.testing.expectEqual(value, copy);
            }

            // NOTE: expectEqual does not do structural equality for slices.
        }
    };

    const testTypeAlloc = TestTypeAlloc{
        .u = .{ .y = 5 },
        .e = .One,
        .s = "abcdefgh",
        .point = .{ 1.1, 2.2 },
        .o = 255,
    };

    try Integration.validateAlloc(TestTypeAlloc, testTypeAlloc, examples.test_type_alloc);
    try Integration.validateAlloc(TestUnion, .{ .x = 6 }, examples.test_union);
    try Integration.validateAlloc(TestEnum, .Two, examples.test_enum);
    try Integration.validateAlloc(?u8, null, examples.none);
    try Integration.validateAlloc(i8, 100, examples.int_i8);
    try Integration.validateAlloc(u8, 101, examples.int_u8);
    try Integration.validateAlloc(i16, 102, examples.int_i16);
    try Integration.validateAlloc(u16, 103, examples.int_u16);
    try Integration.validateAlloc(i32, 104, examples.int_i32);
    try Integration.validateAlloc(u32, 105, examples.int_u32);
    try Integration.validateAlloc(i64, 106, examples.int_i64);
    try Integration.validateAlloc(u64, 107, examples.int_u64);
    try Integration.validateAlloc(i128, 108, examples.int_i128);
    try Integration.validateAlloc(u128, 109, examples.int_u128);
    try Integration.validateAlloc(f32, 5.5, examples.int_f32);
    try Integration.validateAlloc(f64, 6.6, examples.int_f64);
    try Integration.validateAlloc(bool, false, examples.bool_false);
    try Integration.validateAlloc(bool, true, examples.bool_true);

    const testType = TestType{
        .u = .{ .y = 5 },
        .e = .One,
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

    try Integration.validateBuffer(TestTypeAlloc, testTypeAlloc, examples.test_type_alloc);
    try Integration.validateBuffer(TestType, testType, examples.test_type);
    try Integration.validateBuffer(TestUnion, .{ .x = 6 }, examples.test_union);
    try Integration.validateBuffer(TestEnum, .Two, examples.test_enum);
    try Integration.validateBuffer(?u8, null, examples.none);
    try Integration.validateBuffer(i8, 100, examples.int_i8);
    try Integration.validateBuffer(u8, 101, examples.int_u8);
    try Integration.validateBuffer(i16, 102, examples.int_i16);
    try Integration.validateBuffer(u16, 103, examples.int_u16);
    try Integration.validateBuffer(i32, 104, examples.int_i32);
    try Integration.validateBuffer(u32, 105, examples.int_u32);
    try Integration.validateBuffer(i64, 106, examples.int_i64);
    try Integration.validateBuffer(u64, 107, examples.int_u64);
    try Integration.validateBuffer(i128, 108, examples.int_i128);
    try Integration.validateBuffer(u128, 109, examples.int_u128);
    try Integration.validateBuffer(f32, 5.5, examples.int_f32);
    try Integration.validateBuffer(f64, 6.6, examples.int_f64);
    try Integration.validateBuffer(bool, false, examples.bool_false);
    try Integration.validateBuffer(bool, true, examples.bool_true);

    var iterator = deserializeSliceIterator(TestTypeAlloc, examples.test_type_alloc);
    var first = iterator.next().?;
    try first.validate(testTypeAlloc);
    try expectEqual(@as(?TestTypeAlloc, null), iterator.next());
}

test "example" {
    const bincode = @This(); //@import("bincode-zig");

    const Shared = struct {
        name: []const u8,
        age: u32,
    };

    const example = Shared{ .name = "Cat", .age = 5 };

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
