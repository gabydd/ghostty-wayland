const ghostty = @import("ghostty");
const std = @import("std");

const log = std.log;
const posix = std.posix;

const cli = ghostty.cli;
const input = ghostty.input;
const internal_os = ghostty.internal_os;
const renderer = ghostty.renderer;
const terminal = ghostty.terminal;
const Renderer = renderer.Renderer;
const apprt = ghostty.apprt;
const CoreApp = ghostty.App;
const CoreSurface = ghostty.Surface;
const configpkg = ghostty.config;
const Config = configpkg.Config;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const xkb = @import("xkbcommon");
const Keysym = @import("Keysym.zig").Keysym;

const gl = ghostty.gl;
const egl = @cImport({
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cUndef("WL_EGL_PLATFORM");
});

const SurfaceMap = std.AutoArrayHashMap(u32, *Surface);
const SeatList = std.SinglyLinkedList(Seat);
const Context = struct {
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    surface_map: *SurfaceMap,
    seats: *SeatList,
    alloc: std.mem.Allocator,
};

const ModIndex = struct {
    shift: xkb.ModIndex,
    ctrl: xkb.ModIndex,
    alt: xkb.ModIndex,
    super: xkb.ModIndex,
    caps_lock: xkb.ModIndex,
    num_lock: xkb.ModIndex,
};
const Seat = struct {
    surface_map: *SurfaceMap,
    surface: ?*Surface,
    xkb_state: ?*xkb.State,
    mod_index: ModIndex,
};

fn pointerListener(wl_pointer: *wl.Pointer, event: wl.Pointer.Event, seat: *Seat) void {
    _ = wl_pointer;
    switch (event) {
        .enter => |ev| {
            const wl_surface = ev.surface orelse return;
            const id = wl_surface.getId();
            seat.surface = seat.surface_map.get(id);
            const surface = seat.surface orelse return;
            const x: f32 = @floatCast(ev.surface_x.toDouble());
            const y: f32 = @floatCast(ev.surface_y.toDouble());
            surface.cursor_x = x;
            surface.cursor_y = y;
            surface.core_surface.cursorPosCallback(.{
                .x = @floatCast(x),
                .y = @floatCast(y),
            }, null) catch |err| {
                log.err(
                    "error in cursor pos callback err={}",
                    .{err},
                );
                return;
            };
        },
        .leave => {
            seat.surface = null;
            const surface = seat.surface orelse return;
            surface.cursor_x = -1;
            surface.cursor_y = -1;
            surface.core_surface.cursorPosCallback(.{
                .x = -1,
                .y = -1,
            }, null) catch |err| {
                log.err(
                    "error in cursor pos callback err={}",
                    .{err},
                );
                return;
            };
        },
        .motion => |ev| {
            const surface = seat.surface orelse return;
            const x: f32 = @floatCast(ev.surface_x.toDouble());
            const y: f32 = @floatCast(ev.surface_y.toDouble());
            surface.cursor_x = x;
            surface.cursor_y = y;
            surface.core_surface.cursorPosCallback(.{
                .x = x,
                .y = y,
            }, null) catch |err| {
                log.err(
                    "error in cursor pos callback err={}",
                    .{err},
                );
                return;
            };
        },
        .button => |ev| {
            const surface = seat.surface orelse return;
            const xkb_state = surface.xkb_state orelse return;

            // https://github.com/torvalds/linux/blob/ccb98ccef0e543c2bd4ef1a72270461957f3d8d0/include/uapi/linux/input-event-codes.h#L343C1-L363C24
            // #define BTN_MISC    0x100
            // #define BTN_0       0x100
            // #define BTN_1       0x101
            // #define BTN_2       0x102
            // #define BTN_3       0x103
            // #define BTN_4       0x104
            // #define BTN_5       0x105
            // #define BTN_6       0x106
            // #define BTN_7       0x107
            // #define BTN_8       0x108
            // #define BTN_9       0x109
            //
            // #define BTN_MOUSE   0x110
            // #define BTN_LEFT    0x110
            // #define BTN_RIGHT   0x111
            // #define BTN_MIDDLE  0x112
            // #define BTN_SIDE    0x113
            // #define BTN_EXTRA   0x114
            // #define BTN_FORWARD 0x115
            // #define BTN_BACK    0x116
            // #define BTN_TASK    0x117
            const button: input.MouseButton = switch (ev.button) {
                0x110 => .left,
                0x111 => .right,
                0x112 => .middle,
                0x104 => .four,
                0x105 => .five,
                0x106 => .six,
                0x107 => .seven,
                0x108 => .eight,
                0x109 => .nine,
                else => .unknown,
            };

            const action: input.MouseButtonState = switch (ev.state) {
                .pressed => .press,
                .released => .release,
                else => unreachable,
            };
            const components: xkb.State.Component = @enumFromInt(xkb.State.Component.mods_depressed | xkb.State.Component.mods_latched);
            const mods: input.Mods = .{
                .shift = xkb_state.modIndexIsActive(surface.mod_index.shift, components) == 1,
                .ctrl = xkb_state.modIndexIsActive(surface.mod_index.ctrl, components) == 1,
                .alt = xkb_state.modIndexIsActive(surface.mod_index.alt, components) == 1,
                .super = xkb_state.modIndexIsActive(surface.mod_index.super, components) == 1,
                .num_lock = xkb_state.modIndexIsActive(surface.mod_index.num_lock, components) == 1,
                .caps_lock = xkb_state.modIndexIsActive(surface.mod_index.caps_lock, components) == 1,
            };
            _ = surface.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
                log.err("error in scroll callback err={}", .{err});
                return;
            };
        },
        .axis => |ev| {
            const surface = seat.surface orelse return;
            const value = ev.value.toDouble();
            var xoff: f64 = 0;
            var yoff: f64 = 0;
            switch (ev.axis) {
                .vertical_scroll => {
                    yoff = -value;
                },
                .horizontal_scroll => {
                    xoff = value;
                },
                else => unreachable,
            }
            surface.core_surface.scrollCallback(xoff, yoff, .{}) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
        },
        .frame => {
            // TODO make sure events are collected and then
            // dispatched here
        },
        .axis_source => {},
        .axis_discrete => {},
        .axis_stop => {},
    }
}
fn keyboardListener(wl_keyboard: *wl.Keyboard, event: wl.Keyboard.Event, seat: *Seat) void {
    _ = wl_keyboard;
    switch (event) {
        .enter => |ev| {
            const wl_surface = ev.surface orelse return;
            const id = wl_surface.getId();
            seat.surface = seat.surface_map.get(id);
            const surface = seat.surface orelse return;
            surface.xkb_state = seat.xkb_state;
            surface.mod_index = seat.mod_index;
            // It doesn't matter which surface gains keyboard focus or what keys are
            // currently pressed. We don't implement key repeat for simiplicity.
        },
        .leave => {
            // There's nothing to do as we don't implement key repeat and
            // only care about press events, not release.
        },
        .keymap => |ev| {
            defer posix.close(ev.fd);

            if (ev.format != .xkb_v1) {
                log.err("unsupported keymap format {d}", .{@intFromEnum(ev.format)});
                return;
            }

            const keymap_string = posix.mmap(null, ev.size, posix.PROT.READ, .{ .TYPE = .PRIVATE }, ev.fd, 0) catch |err| {
                log.err("failed to mmap() keymap fd: {s}", .{@errorName(err)});
                return;
            };
            defer posix.munmap(keymap_string);

            const context = xkb.Context.new(.no_flags) orelse return;
            const keymap = xkb.Keymap.newFromBuffer(
                context,
                keymap_string.ptr,
                // The string is 0 terminated
                keymap_string.len - 1,
                .text_v1,
                .no_flags,
            ) orelse {
                log.err("failed to parse xkb keymap", .{});
                return;
            };
            defer keymap.unref();

            const state = xkb.State.new(keymap) orelse {
                log.err("failed to create xkb state", .{});
                return;
            };
            defer state.unref();
            seat.mod_index.shift = keymap.modGetIndex(xkb.names.mod.shift);
            seat.mod_index.ctrl = keymap.modGetIndex(xkb.names.mod.ctrl);
            seat.mod_index.alt = keymap.modGetIndex(xkb.names.mod.alt);
            seat.mod_index.caps_lock = keymap.modGetIndex(xkb.names.mod.caps);
            seat.mod_index.num_lock = keymap.modGetIndex(xkb.names.mod.num);
            seat.mod_index.super = keymap.modGetIndex(xkb.names.mod.logo);

            if (seat.xkb_state) |s| s.unref();
            seat.xkb_state = state.ref();
            const surface = seat.surface orelse return;
            surface.xkb_state = seat.xkb_state;
            surface.mod_index = seat.mod_index;
        },
        .modifiers => |ev| {
            if (seat.xkb_state) |xkb_state| {
                _ = xkb_state.updateMask(
                    ev.mods_depressed,
                    ev.mods_latched,
                    ev.mods_locked,
                    0,
                    0,
                    ev.group,
                );
            }
        },
        .key => |ev| {
            const surface = seat.surface orelse return;
            const action: input.Action = switch (ev.state) {
                .released => .release,
                .pressed => .press,
                else => unreachable,
            };
            const xkb_state = seat.xkb_state orelse return;
            const components: xkb.State.Component = @enumFromInt(xkb.State.Component.mods_depressed | xkb.State.Component.mods_latched);
            const mods: input.Mods = .{
                .shift = xkb_state.modIndexIsActive(seat.mod_index.shift, components) == 1,
                .ctrl = xkb_state.modIndexIsActive(seat.mod_index.ctrl, components) == 1,
                .alt = xkb_state.modIndexIsActive(seat.mod_index.alt, components) == 1,
                .super = xkb_state.modIndexIsActive(seat.mod_index.super, components) == 1,
                .num_lock = xkb_state.modIndexIsActive(seat.mod_index.num_lock, components) == 1,
                .caps_lock = xkb_state.modIndexIsActive(seat.mod_index.caps_lock, components) == 1,
            };

            // The wayland protocol gives us an input event code. To convert this to an xkb
            // keycode we must add 8.
            const keycode = ev.key + 8;
            const consumed_mods: input.Mods = .{
                .shift = xkb_state.modIndexIsConsumed2(keycode, seat.mod_index.shift, .gtk) == 1,
                .ctrl = xkb_state.modIndexIsConsumed2(keycode, seat.mod_index.ctrl, .gtk) == 1,
                .alt = xkb_state.modIndexIsConsumed2(keycode, seat.mod_index.alt, .gtk) == 1,
                .super = xkb_state.modIndexIsConsumed2(keycode, seat.mod_index.super, .gtk) == 1,
                .num_lock = xkb_state.modIndexIsConsumed2(keycode, seat.mod_index.num_lock, .gtk) == 1,
                .caps_lock = xkb_state.modIndexIsConsumed2(keycode, seat.mod_index.caps_lock, .gtk) == 1,
            };

            const keysym: Keysym = @enumFromInt(@intFromEnum(xkb_state.keyGetOneSym(keycode)));
            const lower: u21 = @intCast(keysym.toLower().toUTF32());
            if (keysym == .NoSymbol) return;
            const key: input.Key = switch (keysym) {
                .a => .a,
                .b => .b,
                .c => .c,
                .d => .d,
                .e => .e,
                .f => .f,
                .g => .g,
                .h => .h,
                .i => .i,
                .j => .j,
                .k => .k,
                .l => .l,
                .m => .m,
                .n => .n,
                .o => .o,
                .p => .p,
                .q => .q,
                .r => .r,
                .s => .s,
                .t => .t,
                .u => .u,
                .v => .v,
                .w => .w,
                .x => .x,
                .y => .y,
                .z => .z,
                .@"0" => .zero,
                .@"1" => .one,
                .@"2" => .two,
                .@"3" => .three,
                .@"4" => .four,
                .@"5" => .five,
                .@"6" => .six,
                .@"7" => .seven,
                .@"8" => .eight,
                .@"9" => .nine,
                .Up => .up,
                .Down => .down,
                .Right => .right,
                .Left => .left,
                .Home => .home,
                .End => .end,
                .Page_Up => .page_up,
                .Page_Down => .page_down,
                .Escape => .escape,

                .KP_Decimal => .kp_decimal,
                .KP_Divide => .kp_divide,
                .KP_Multiply => .kp_multiply,
                .KP_Subtract => .kp_subtract,
                .KP_Add => .kp_add,
                .KP_Enter => .kp_enter,
                .KP_Equal => .kp_equal,
                .grave => .grave_accent,
                .minus => .minus,
                .equal => .equal,
                .space => .space,
                .semicolon => .semicolon,
                .apostrophe => .apostrophe,
                .comma => .comma,
                .period => .period,
                .slash => .slash,
                .bracketleft => .left_bracket,
                .bracketright => .right_bracket,
                .backslash => .backslash,
                .Return => .enter,
                .Tab => .tab,
                .BackSpace => .backspace,
                .Delete => .delete,

                .Shift_L => .left_shift,
                .Control_L => .left_control,
                .Alt_L => .left_alt,
                .Super_L => .left_super,
                .Shift_R => .right_shift,
                .Control_R => .right_control,
                .Alt_R => .right_alt,
                .Super_R => .right_super,
                else => .invalid,
            };
            var buf: [3]u8 = undefined;
            const utf32 = keysym.toUTF32();
            const utf8_len: u3 = if (utf32 < 0x20) 0 else std.unicode.utf8Encode(@intCast(utf32), &buf) catch return;
            const utf8: []const u8 = buf[0..utf8_len];
            const key_event: input.KeyEvent = .{
                .action = action,
                .key = key,
                .physical_key = key,
                .mods = mods,
                .consumed_mods = consumed_mods,
                .composing = false,
                .utf8 = utf8,
                .unshifted_codepoint = lower,
            };

            const effect = surface.core_surface.keyCallback(key_event) catch |err| {
                log.err("error in key callback err={}", .{err});
                return;
            };

            // Surface closed.
            if (effect == .closed) return;
        },
        .repeat_info => |_| {},
    }
}
fn seatListener(wl_seat: *wl.Seat, event: wl.Seat.Event, seat: *Seat) void {
    switch (event) {
        .name => {},
        .capabilities => |ev| {
            if (ev.capabilities.pointer) {
                const wl_pointer = wl_seat.getPointer() catch {
                    log.err("failed to allocate memory for wl_pointer object", .{});
                    return;
                };
                wl_pointer.setListener(*Seat, pointerListener, seat);
            }

            if (ev.capabilities.keyboard) {
                const wl_keyboard = wl_seat.getKeyboard() catch {
                    log.err("failed to allocate memory for wl_keyboard object", .{});
                    return;
                };
                wl_keyboard.setListener(*Seat, keyboardListener, seat);
            }
        },
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                const wl_seat = registry.bind(global.name, wl.Seat, 5) catch return;
                const seat = context.alloc.create(SeatList.Node) catch return;
                context.seats.prepend(seat);
                seat.data.surface_map = context.surface_map;
                seat.data.surface = null;
                seat.data.xkb_state = null;
                wl_seat.setListener(
                    *Seat,
                    seatListener,
                    &seat.data,
                );
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            }
        },
        .global_remove => {},
    }
}
pub const App = struct {
    app: *CoreApp,
    config: Config,
    display: *wl.Display,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,
    registry: *wl.Registry,

    egl_display: ?*anyopaque,
    egl_config: *anyopaque,
    surface_map: *SurfaceMap,
    seats: *SeatList,

    pub const Options = struct {};
    pub fn init(core_app: *CoreApp, _: Options) !App {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        const surface_map = try core_app.alloc.create(SurfaceMap);
        surface_map.* = SurfaceMap.init(core_app.alloc);

        const seats = try core_app.alloc.create(SeatList);
        seats.* = .{};

        var context: Context = .{
            .compositor = null,
            .wm_base = null,
            .surface_map = surface_map,
            .alloc = core_app.alloc,
            .seats = seats,
        };
        registry.setListener(*Context, registryListener, &context);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = context.compositor orelse return error.NoWlCompositor;
        const wm_base = context.wm_base orelse return error.NoXdgWmBase;
        const egl_display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);
        var egl_major: egl.EGLint = 0;

        var egl_minor: egl.EGLint = 0;
        if (egl.eglInitialize(egl_display, &egl_major, &egl_minor) == egl.EGL_TRUE) {
            log.info("EGL version: {}.{}", .{ egl_major, egl_minor });
        } else switch (egl.eglGetError()) {
            egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
            else => return error.EglFailedToinitialize,
        }
        const egl_attributes: [12:egl.EGL_NONE]egl.EGLint = .{
            egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
        };
        const egl_config = config: {
            // Rather ask for a list of possible configs, we just get the first one and
            // hope it is a good choice.
            var config: egl.EGLConfig = null;
            var num_configs: egl.EGLint = 0;
            const result = egl.eglChooseConfig(
                egl_display,
                &egl_attributes,
                &config,
                1,
                &num_configs,
            );

            if (result != egl.EGL_TRUE) {
                switch (egl.eglGetError()) {
                    egl.EGL_BAD_ATTRIBUTE => return error.InvalidEglConfigAttribute,
                    else => return error.EglConfigError,
                }
            }
            break :config config orelse return error.NoEglConfig;
        };
        if (egl.eglBindAPI(egl.EGL_OPENGL_API) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return error.OpenGlUnsupported,
                else => return error.InvalidApi,
            }
        }

        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // If we had configuration errors, then log them.
        if (!config._diagnostics.empty()) {
            var buf = std.ArrayList(u8).init(core_app.alloc);
            defer buf.deinit();
            for (config._diagnostics.items()) |diag| {
                try diag.write(buf.writer());
                log.warn("configuration error: {s}", .{buf.items});
                buf.clearRetainingCapacity();
            }

            // If we have any CLI errors, exit.
            if (config._diagnostics.containsLocation(.cli)) {
                log.warn("CLI errors detected, exiting", .{});
                _ = core_app.mailbox.push(.{
                    .quit = {},
                }, .{ .forever = {} });
            }
        }

        // Queue a single new window that starts on launch
        // Note: above we may send a quit so this may never happen
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        return .{
            .app = core_app,
            .config = config,
            .compositor = compositor,
            .wm_base = wm_base,
            .registry = registry,
            .egl_display = egl_display,
            .egl_config = egl_config,
            .display = display,
            .surface_map = surface_map,
            .seats = seats,
        };
    }

    pub fn terminate(self: *App) void {
        self.config.deinit();
        self.deinit();
        self.registry.destroy();
        self.wm_base.destroy();
        self.compositor.destroy();
        self.display.disconnect();
    }

    fn deinit(self: *App) void {
        self.surface_map.deinit();
        self.app.alloc.destroy(self.surface_map);
        while (self.seats.popFirst()) |seat| {
            self.app.alloc.destroy(seat);
        }
        self.app.alloc.destroy(self.seats);
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !void {
        switch (action) {
            .new_window => _ = try self.newSurface(switch (target) {
                .app => null,
                .surface => |v| v,
            }),
            .reload_config => try self.reloadConfig(target, value),
            .new_tab,
            .toggle_fullscreen,
            .size_limit,
            .initial_size,
            .set_title,
            .mouse_shape,
            .mouse_visibility,
            .open_config,

            .new_split,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .present_terminal,
            .close_all_windows,
            .toggle_tab_overview,
            .toggle_window_decorations,
            .toggle_quick_terminal,
            .toggle_visibility,
            .goto_tab,
            .move_tab,
            .inspector,
            .render_inspector,
            .quit_timer,
            .secure_input,
            .key_sequence,
            .desktop_notification,
            .mouse_over_link,
            .cell_size,
            .renderer_health,
            .color_change,
            .pwd,
            .config_change,
            => log.info("unimplemented action={}", .{action}),
        }
    }

    /// Reload the configuration. This should return the new configuration.
    /// The old value can be freed immediately at this point assuming a
    /// successful return.
    ///
    /// The returned pointer value is only valid for a stable self pointer.
    fn reloadConfig(
        self: *App,
        target: apprt.action.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        if (opts.soft) {
            switch (target) {
                .app => try self.app.updateConfig(self, &self.config),
                .surface => |core_surface| try core_surface.updateConfig(
                    &self.config,
                ),
            }
            return;
        }

        // Load our configuration
        var config = try Config.load(self.app.alloc);
        errdefer config.deinit();

        // Call into our app to update
        switch (target) {
            .app => try self.app.updateConfig(self, &config),
            .surface => |core_surface| try core_surface.updateConfig(&config),
        }

        // Update the existing config, be sure to clean up the old one.
        self.config.deinit();
        self.config = config;
    }

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        @panic("This should never be called for wayland.");
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        // wayland doesn't support the inspector
    }

    pub fn run(self: *App) !void {
        _ = try self.app.tick(self);
        while (true) {
            const err = self.display.dispatch();
            if (err != .SUCCESS) {
                log.err("{}", .{err});
                return error.DispatchFailed;
            }

            // Tick the terminal app
            const should_quit = try self.app.tick(self);
            if (should_quit or self.app.surfaces.items.len == 0) {
                for (self.app.surfaces.items) |surface| {
                    surface.close(false);
                }

                return;
            }
        }
    }

    pub fn wakeup(self: *App) void {
        _ = self;
    }

    pub fn newSurface(self: *App, parent_: ?*CoreSurface) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.app.alloc.create(Surface);
        errdefer self.app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces for glfw.
        try surface.init(self);
        errdefer surface.deinit();

        // If we have a parent, inherit some properties
        if (self.config.@"window-inherit-font-size") {
            if (parent_) |parent| {
                try surface.core_surface.setFontSize(parent.font_size);
            }
        }

        const surface_id: u32 = surface.wl_surface.getId();
        try self.surface_map.put(surface_id, surface);
        return surface;
    }
};

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *Surface) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            const size: apprt.SurfaceSize = .{ .width = surface.width, .height = surface.height };
            surface.egl_window.resize(@intCast(size.width), @intCast(size.height), 0, 0);

            // Call the primary callback.
            surface.core_surface.sizeCallback(size) catch |err| {
                log.err("error in size callback err={}", .{err});
                return;
            };
            surface.configured = true;
            surface.wl_surface.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, surface: *Surface) void {
    switch (event) {
        .configure => |configure| {
            surface.width = @intCast(configure.width);
            surface.height = @intCast(configure.height);
        },
        .close => surface.should_close = true,
    }
}

pub const Surface = struct {
    /// The app we're part of
    app: *App,

    /// A core surface
    core_surface: CoreSurface,

    wl_surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    egl_window: *wl.EglWindow,
    egl_surface: *anyopaque,
    egl_context: ?*anyopaque,

    title_text: ?[:0]const u8,
    should_close: bool,
    width: u32,
    height: u32,
    cursor_x: f32,
    cursor_y: f32,
    configured: bool,
    xkb_state: ?*xkb.State,
    mod_index: ModIndex,

    pub fn init(self: *Surface, app: *App) !void {
        self.egl_context = null;
        self.title_text = null;
        self.app = app;
        self.should_close = false;
        self.configured = false;
        self.cursor_x = -1;
        self.cursor_y = -1;
        self.xkb_state = null;

        self.wl_surface = try app.compositor.createSurface();
        errdefer self.wl_surface.destroy();
        self.xdg_surface = try app.wm_base.getXdgSurface(self.wl_surface);
        errdefer self.xdg_surface.destroy();
        self.xdg_toplevel = try self.xdg_surface.getToplevel();
        errdefer self.xdg_toplevel.destroy();
        self.xdg_surface.setListener(*Surface, xdgSurfaceListener, self);
        self.xdg_toplevel.setListener(*Surface, xdgToplevelListener, self);

        self.egl_window = try wl.EglWindow.create(self.wl_surface, 500, 500);
        self.height = 500;
        self.width = 500;

        self.egl_surface = egl.eglCreatePlatformWindowSurface(
            self.app.egl_display,
            self.app.egl_config,
            @ptrCast(self.egl_window),
            null,
        ) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidWindow,
            else => return error.FailedToCreateEglSurface,
        };
        self.wl_surface.commit();
        // Add ourselves to the list of surfaces on the app.
        try app.app.addSurface(self);
        errdefer app.app.deleteSurface(self);

        // Get our new surface config
        var config = try apprt.surface.newConfig(app.app, &app.config);
        defer config.deinit();

        // Initialize our surface now that we have the stable pointer.
        try self.core_surface.init(
            app.app.alloc,
            &config,
            app.app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();
    }
    pub fn deinit(self: *Surface) void {
        if (self.title_text) |t| self.core_surface.alloc.free(t);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();

        self.xdg_toplevel.destroy();
        self.xdg_surface.destroy();
        self.wl_surface.destroy();
    }
    pub fn shouldClose(self: *Surface) bool {
        return self.should_close;
    }
    pub fn close(self: *Surface, proccess_active: bool) void {
        _ = proccess_active; // autofix
        self.should_close = true;
        self.deinit();
        self.app.app.alloc.destroy(self);
    }
    /// Set the title of the window.
    fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        if (self.title_text) |t| self.core_surface.alloc.free(t);
        self.title_text = try self.core_surface.alloc.dupeZ(u8, slice);
        // TODO: actually set title
    }

    /// Return the title of the window.
    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title_text;
    }
    /// Returns the content scale for the created window.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self; // autofix
        return apprt.ContentScale{ .x = 1, .y = 1 };
    }

    /// Returns the size of the window in pixels. The pixel size may
    /// not match screen coordinate size but we should be able to convert
    /// back and forth using getContentScale.
    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return apprt.SurfaceSize{ .width = self.width, .height = self.height };
    }

    /// Returns the cursor position in scaled pixels relative to the
    /// upper-left of the window.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return apprt.CursorPos{
            .x = self.cursor_x,
            .y = self.cursor_y,
        };
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = clipboard_type; // autofix
        _ = self;
        return false;
        // return switch (clipboard_type) {
        //     .standard => true,
        //     .selection, .primary => comptime builtin.os.tag == .linux,
        // };
    }

    /// Start an async clipboard request.
    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !void {
        _ = state; // autofix
        _ = clipboard_type; // autofix
        _ = self; // autofix
    }

    /// Set the clipboard.
    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        _ = confirm; // autofix
        _ = clipboard_type; // autofix
        _ = val; // autofix
        _ = self; // autofix
    }

    pub fn threadEnter(self: *Surface) !void {
        if (self.egl_context == null) {
            const context_attributes: [4:egl.EGL_NONE]egl.EGLint = .{
                egl.EGL_CONTEXT_MAJOR_VERSION, 4,
                egl.EGL_CONTEXT_MINOR_VERSION, 6,
            };
            self.egl_context = egl.eglCreateContext(
                self.app.egl_display,
                self.app.egl_config,
                egl.EGL_NO_CONTEXT,
                &context_attributes,
            ) orelse switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
                egl.EGL_BAD_CONFIG => return error.CreateContextWithBadConfig,
                egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
                else => return error.FailedToCreateContext,
            };
        }
        const result = egl.eglMakeCurrent(
            self.app.egl_display,
            self.egl_surface,
            self.egl_surface,
            self.egl_context,
        );

        if (result == egl.EGL_FALSE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.FailedToMakeCurrent,
            }
        }

        const version = try gl.glad.load(egl.eglGetProcAddress);
        errdefer gl.glad.unload();
        log.err("loaded OpenGL {}.{}", .{
            gl.glad.versionMajor(@intCast(version)),
            gl.glad.versionMinor(@intCast(version)),
        });
    }

    pub fn swapBuffers(self: *Surface) !void {
        if (!self.configured) return;
        if (egl.eglSwapBuffers(self.app.egl_display, self.egl_surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.PresentInvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.EGLContextLost,
                else => return error.FailedToSwapBuffers,
            }
        }
    }
    pub fn finalizeSurfaceInit(self: *Surface) !void {
        const result = egl.eglMakeCurrent(
            self.app.egl_display,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_CONTEXT,
        );

        if (result == egl.EGL_FALSE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.FailedToMakeCurrent,
            }
        }
    }

    pub fn threadExit(self: *Surface) void {
        gl.glad.unload();
        _ = egl.eglMakeCurrent(
            self.app.egl_display,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_CONTEXT,
        );
    }
};
