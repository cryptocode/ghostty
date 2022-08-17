//! Tracy API.
//!
//! Forked and modified from https://github.com/SpexGuy/Zig-Tracy
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const SourceLocation = std.builtin.SourceLocation;

// Tracy is enabled if the root function tracy_enabled returns true.
pub const enabled = @hasDecl(root, "tracy_enabled") and root.tracy_enabled();

// Bring in the correct implementation depending on if we're enabled or not.
// See Impl for all the real doc comments.
pub usingnamespace if (enabled) Impl else Noop;

const Impl = struct {
    const c = @cImport({
        @cDefine("TRACY_ENABLE", "");
        @cInclude("TracyC.h");
    });

    const has_callstack_support = @hasDecl(c, "TRACY_HAS_CALLSTACK") and @hasDecl(c, "TRACY_CALLSTACK");
    const callstack_enabled: c_int = if (has_callstack_support) c.TRACY_CALLSTACK else 0;
    const callstack_depth = 10; // TODO configurable

    /// A zone represents the lifetime of a special on-stack profiler variable.
    /// Typically it would exist for the duration of a whole scope of the
    /// profiled function, but you also can measure time spent in scopes of a
    /// for-loop or an if-branch.
    pub const Zone = struct {
        zone: c.___tracy_c_zone_context,

        /// Text description of a zone.
        pub inline fn text(self: Zone, val: []const u8) void {
            c.___tracy_emit_zone_text(self.zone, val.ptr, val.len);
        }

        /// Name of the zone.
        pub inline fn name(self: Zone, val: []const u8) void {
            c.___tracy_emit_zone_name(self.zone, val.ptr, val.len);
        }

        /// Color of the zone in the UI. Specify the value as RGB
        /// using hex: 0xRRGGBB.
        pub inline fn color(self: Zone, val: u32) void {
            c.___tracy_emit_zone_color(self.zone, val);
        }

        /// A value associated with the zone.
        pub inline fn value(self: Zone, val: u64) void {
            c.___tracy_emit_zone_value(self.zone, val);
        }

        /// End the zone.
        pub inline fn end(self: Zone) void {
            c.___tracy_emit_zone_end(self.zone);
        }
    };

    /// Tracy profiles within the context of a frame. This represents
    /// a single frame.
    pub fn Frame(comptime name: [:0]const u8) type {
        return struct {
            pub fn end(_: @This()) void {
                c.___tracy_emit_frame_mark_end(name.ptr);
            }
        };
    }

    /// allocator returns an allocator that tracks allocs/frees.
    pub fn allocator(
        parent: std.mem.Allocator,
        comptime name: ?[:0]const u8,
    ) Allocator(name) {
        return Allocator(name).init(parent);
    }

    /// Returns an allocator type with the given name.
    pub fn Allocator(comptime name: ?[:0]const u8) type {
        return struct {
            parent: std.mem.Allocator,

            const Self = @This();

            pub fn init(parent: std.mem.Allocator) Self {
                return .{ .parent = parent };
            }

            pub fn allocator(self: *Self) std.mem.Allocator {
                return std.mem.Allocator.init(self, allocFn, resizeFn, freeFn);
            }

            fn allocFn(
                self: *Self,
                len: usize,
                ptr_align: u29,
                len_align: u29,
                ret_addr: usize,
            ) std.mem.Allocator.Error![]u8 {
                const result = self.parent.rawAlloc(len, ptr_align, len_align, ret_addr);
                if (result) |data| {
                    if (data.len != 0) {
                        if (name) |n| {
                            allocNamed(data.ptr, data.len, n);
                        } else {
                            alloc(data.ptr, data.len);
                        }
                    }
                } else |_| {
                    //messageColor("allocation failed", 0xFF0000);
                }
                return result;
            }

            fn resizeFn(
                self: *Self,
                buf: []u8,
                buf_align: u29,
                new_len: usize,
                len_align: u29,
                ret_addr: usize,
            ) ?usize {
                if (self.parent.rawResize(buf, buf_align, new_len, len_align, ret_addr)) |resized_len| {
                    if (name) |n| {
                        freeNamed(buf.ptr, n);
                        allocNamed(buf.ptr, resized_len, n);
                    } else {
                        free(buf.ptr);
                        alloc(buf.ptr, resized_len);
                    }

                    return resized_len;
                }

                // during normal operation the compiler hits this case thousands of times due to this
                // emitting messages for it is both slow and causes clutter
                return null;
            }

            fn freeFn(self: *Self, buf: []u8, buf_align: u29, ret_addr: usize) void {
                self.parent.rawFree(buf, buf_align, ret_addr);

                if (buf.len != 0) {
                    if (name) |n| {
                        freeNamed(buf.ptr, n);
                    } else {
                        free(buf.ptr);
                    }
                }
            }
        };
    }

    /// Start a trace. Defer calling end() to end the trace.
    pub inline fn trace(comptime src: SourceLocation) Zone {
        const static = struct {
            var loc: c.___tracy_source_location_data = undefined;
        };
        static.loc = .{
            .name = null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };

        const zone = if (has_callstack_support)
            c.___tracy_emit_zone_begin_callstack(&static.loc, callstack_depth, 1)
        else
            c.___tracy_emit_zone_begin(&static.loc, 1);

        return Zone{ .zone = zone };
    }

    /// Mark the boundary of a frame. Good for continuous frames. For
    /// discontinous frames, use frame() and defer end().
    pub inline fn frameMark() void {
        c.___tracy_emit_frame_mark(null);
    }

    /// Start a discontinuous frame.
    pub inline fn frame(comptime name: [:0]const u8) Frame(name) {
        c.___tracy_emit_frame_mark_start(name.ptr);
        return .{};
    }

    inline fn alloc(ptr: [*]u8, len: usize) void {
        if (has_callstack_support) {
            c.___tracy_emit_memory_alloc_callstack(ptr, len, callstack_depth, 0);
        } else {
            c.___tracy_emit_memory_alloc(ptr, len, 0);
        }
    }

    inline fn allocNamed(ptr: [*]u8, len: usize, comptime name: [:0]const u8) void {
        if (has_callstack_support) {
            c.___tracy_emit_memory_alloc_callstack_named(ptr, len, callstack_depth, 0, name.ptr);
        } else {
            c.___tracy_emit_memory_alloc_named(ptr, len, 0, name.ptr);
        }
    }

    inline fn free(ptr: [*]u8) void {
        if (has_callstack_support) {
            c.___tracy_emit_memory_free_callstack(ptr, callstack_depth, 0);
        } else {
            c.___tracy_emit_memory_free(ptr, 0);
        }
    }

    inline fn freeNamed(ptr: [*]u8, comptime name: [:0]const u8) void {
        if (has_callstack_support) {
            c.___tracy_emit_memory_free_callstack_named(ptr, callstack_depth, 0, name.ptr);
        } else {
            c.___tracy_emit_memory_free_named(ptr, 0, name.ptr);
        }
    }
};

const Noop = struct {
    pub const Zone = struct {
        pub inline fn text(_: Zone, _: []const u8) void {}
        pub inline fn name(_: Zone, _: []const u8) void {}
        pub inline fn color(_: Zone, _: u32) void {}
        pub inline fn value(_: Zone, _: u64) void {}
        pub inline fn end(_: Zone) void {}
    };

    pub fn Frame(comptime _: [:0]const u8) type {
        return struct {
            pub fn end(_: @This()) void {}
        };
    }

    pub inline fn trace(comptime src: SourceLocation) Zone {
        _ = src;
        return .{};
    }

    pub inline fn frameMark() void {}

    pub inline fn frame(comptime name: [:0]const u8) Frame(name) {
        return .{};
    }
};