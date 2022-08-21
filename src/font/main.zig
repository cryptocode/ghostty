const std = @import("std");

pub const Face = @import("Face.zig");
pub const Family = @import("Family.zig");
pub const Glyph = @import("Glyph.zig");
pub const FallbackSet = @import("FallbackSet.zig");

/// Embedded fonts (for now)
pub const fontRegular = @import("test.zig").fontRegular;
pub const fontBold = @import("test.zig").fontBold;

/// The styles that a family can take.
pub const Style = enum {
    regular,
    bold,
    italic,
    bold_italic,
};

/// Returns the UTF-32 codepoint for the given value.
pub fn codepoint(v: anytype) u32 {
    // We need a UTF32 codepoint for freetype
    return switch (@TypeOf(v)) {
        u32 => v,
        comptime_int, u8 => @intCast(u32, v),
        []const u8 => @intCast(u32, try std.unicode.utfDecode(v)),
        else => @compileError("invalid codepoint type"),
    };
}

test {
    _ = Face;
    _ = Family;
    _ = Glyph;
    _ = FallbackSet;
}