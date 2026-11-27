package vasperty_hle

import "base:intrinsics"
import "core:os"
import "core:sync"
import "core:time"

// =============================================================================
// GameInput HLE (#1 GameInputCreate + XInput + Win32 Keyboard Fallback)
// =============================================================================

GAMEINPUT_READING_NOT_FOUND :: HRESULT(-2088108029) // 0x838A0003

GAMEINPUT_KIND_KEYBOARD      :: u32(0x00000010)
GAMEINPUT_KIND_GAMEPAD       :: u32(0x00040000)
GAMEINPUT_KIND_UI_NAVIGATION :: u32(0x01000000)

GAMEINPUT_DEVICE_CONNECTED     :: u32(0x00000001)
GAMEINPUT_DEVICE_INPUT_ENABLED :: u32(0x00000002)

GAMEINPUT_GAMEPAD_MENU             :: u32(0x00000001)
GAMEINPUT_GAMEPAD_VIEW             :: u32(0x00000002)
GAMEINPUT_GAMEPAD_A                :: u32(0x00000004)
GAMEINPUT_GAMEPAD_B                :: u32(0x00000008)
GAMEINPUT_GAMEPAD_X                :: u32(0x00000010)
GAMEINPUT_GAMEPAD_Y                :: u32(0x00000020)
GAMEINPUT_GAMEPAD_DPAD_UP          :: u32(0x00000040)
GAMEINPUT_GAMEPAD_DPAD_DOWN        :: u32(0x00000080)
GAMEINPUT_GAMEPAD_DPAD_LEFT        :: u32(0x00000100)
GAMEINPUT_GAMEPAD_DPAD_RIGHT       :: u32(0x00000200)
GAMEINPUT_GAMEPAD_LEFT_SHOULDER    :: u32(0x00000400)
GAMEINPUT_GAMEPAD_RIGHT_SHOULDER   :: u32(0x00000800)
GAMEINPUT_GAMEPAD_LEFT_THUMBSTICK  :: u32(0x00001000)
GAMEINPUT_GAMEPAD_RIGHT_THUMBSTICK :: u32(0x00002000)

GameInput_Gamepad_State :: struct {
	buttons:            u32,
	left_trigger:       f32,
	right_trigger:      f32,
	left_thumbstick_x:  f32,
	left_thumbstick_y:  f32,
	right_thumbstick_x: f32,
	right_thumbstick_y: f32,
}

GameInput_Ui_Nav_State :: struct {
	buttons: u32,
}

GameInput_Battery_State :: struct {
	charge_rate:         f32,
	max_charge_capacity: f32,
	remaining_capacity:  f32,
	status:              u32,
}

GameInput_Device_Info :: struct {
	info_size:              u32,
	vendor_id:              u16,
	product_id:             u16,
	revision_number:        u16,
	interface_number:       u8,
	collection_number:      u8,
	usage_page:             u16,
	usage_id:               u16,
	hw_version:             [4]u16,
	fw_version:             [4]u16,
	device_id:              [32]u8,
	device_root_id:         [32]u8,
	device_family:          u32,
	capabilities:           u32,
	supported_input:        u32,
	supported_rumble:       u32,
	_reserved_pad:          [144]u8,
}

#assert(offset_of(GameInput_Device_Info, device_id) == 32)
#assert(offset_of(GameInput_Device_Info, supported_input) == 104)

XInput_Gamepad :: struct {
	buttons:       u16,
	left_trigger:  u8,
	right_trigger: u8,
	thumb_lx:      i16,
	thumb_ly:      i16,
	thumb_rx:      i16,
	thumb_ry:      i16,
}

XInput_State :: struct {
	packet_number: u32,
	gamepad:       XInput_Gamepad,
}

Joy_Info_Ex :: struct {
	dwSize:         u32,
	dwFlags:        u32,
	dwXpos:         u32,
	dwYpos:         u32,
	dwZpos:         u32,
	dwRpos:         u32,
	dwUpos:         u32,
	dwVpos:         u32,
	dwButtons:      u32,
	dwButtonNumber: u32,
	dwPOV:          u32,
	dwReserved1:    u32,
	dwReserved2:    u32,
}

GameInput_Object :: struct {
	vtable: rawptr,
	refs:   u32,
}

GameInput_Device :: struct {
	vtable: rawptr,
	refs:   u32,
}

GameInput_Reading :: struct {
	vtable:  rawptr,
	refs:    u32,
	seq:     u64,
	ts:      u64,
	gamepad: GameInput_Gamepad_State,
}

@(private) gi_mu: sync.Mutex
@(private) gi_seq: u64 = 1
@(private) gi_start_tick: time.Tick
@(private) gi_started: bool
@(private) gi_auto_press_a: bool
@(private) gi_xinput_loaded: bool
@(private) gi_xinput_get_state: proc "system" (user_index: u32, state: ^XInput_State) -> u32
@(private) gi_joy_get_pos_ex: proc "system" (joy_id: u32, pji: ^Joy_Info_Ex) -> u32
@(private) gi_get_async_key_state: proc "system" (vk: i32) -> i16

@(private) gi_device_info := GameInput_Device_Info {
	info_size        = size_of(GameInput_Device_Info),
	vendor_id        = 0x045E,
	product_id       = 0x0B12,
	revision_number  = 1,
	usage_page       = 1,
	usage_id         = 5,
	device_id        = {0 = 0x56, 1 = 0x41, 2 = 0x53, 3 = 0x50, 4 = 0x45, 5 = 0x52, 6 = 0x54, 7 = 0x59, 8 = 0x01},
	device_root_id   = {0 = 0x56, 1 = 0x41, 2 = 0x53, 3 = 0x50, 4 = 0x45, 5 = 0x52, 6 = 0x54, 7 = 0x59, 8 = 0x01},
	device_family    = 2,
	supported_input  = GAMEINPUT_KIND_GAMEPAD | GAMEINPUT_KIND_UI_NAVIGATION,
	supported_rumble = 0xF,
}

@(private) gi_device := GameInput_Device {
	vtable = nil,
	refs   = 1,
}

fini_gameinput :: proc() {
	sync.mutex_lock(&gi_mu)
	gi_started = false
	sync.mutex_unlock(&gi_mu)
}

@(private)
gi_ensure_init :: proc() {
	sync.mutex_lock(&gi_mu)
	defer sync.mutex_unlock(&gi_mu)
	if !gi_started {
		gi_started = true
		gi_start_tick = time.tick_now()
		gi_device.vtable = raw_data(GAMEINPUT_DEVICE_VTABLE[:])
		if v, ok := os.lookup_env("VASPERTY_AUTO_PRESS_A", context.temp_allocator); ok && (v == "1" || v == "true") {
			gi_auto_press_a = true
		} else {
			gi_auto_press_a = false
		}
	}
	if !gi_xinput_loaded {
		gi_xinput_loaded = true
		if fn, ok := host_fn("xinput1_4.dll", "XInputGetState", proc "system" (u32, ^XInput_State) -> u32); ok {
			gi_xinput_get_state = fn
		} else if fn13, ok13 := host_fn("xinput1_3.dll", "XInputGetState", proc "system" (u32, ^XInput_State) -> u32); ok13 {
			gi_xinput_get_state = fn13
		} else if fn2, ok2 := host_fn("xinput9_1_0.dll", "XInputGetState", proc "system" (u32, ^XInput_State) -> u32); ok2 {
			gi_xinput_get_state = fn2
		}
		if jfn, jok := host_fn("winmm.dll", "joyGetPosEx", proc "system" (u32, ^Joy_Info_Ex) -> u32); jok {
			gi_joy_get_pos_ex = jfn
		}
		if kfn, kok := host_fn("user32.dll", "GetAsyncKeyState", proc "system" (i32) -> i16); kok {
			gi_get_async_key_state = kfn
		}
	}
}

@(private)
gi_key_down :: proc(vk: i32) -> bool {
	if gi_get_async_key_state == nil { return false }
	return (u16(gi_get_async_key_state(vk)) & 0x8000) != 0
}

@(private)
gi_norm_stick :: proc(v: i16, deadzone: i16) -> f32 {
	if v > deadzone {
		return f32(v - deadzone) / f32(32767 - deadzone)
	}
	if v < -deadzone {
		return f32(i32(v) + i32(deadzone)) / f32(32768 - i32(deadzone))
	}
	return 0
}

@(private)
gi_sample_gamepad :: proc() -> GameInput_Gamepad_State {
	gi_ensure_init()
	st: GameInput_Gamepad_State

	// 1. Real Xbox controller via XInput (scan all 4 slots 0..3)
	xinput_found := false
	if gi_xinput_get_state != nil {
		for slot in u32(0) ..< 4 {
			xs: XInput_State
			if gi_xinput_get_state(slot, &xs) == 0 {
				xinput_found = true
				xb := xs.gamepad.buttons
				if (xb & 0x0001) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_UP }
				if (xb & 0x0002) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_DOWN }
				if (xb & 0x0004) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_LEFT }
				if (xb & 0x0008) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_RIGHT }
				if (xb & 0x0010) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_MENU }
				if (xb & 0x0020) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_VIEW }
				if (xb & 0x0040) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_LEFT_THUMBSTICK }
				if (xb & 0x0080) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_RIGHT_THUMBSTICK }
				if (xb & 0x0100) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_LEFT_SHOULDER }
				if (xb & 0x0200) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_RIGHT_SHOULDER }
				if (xb & 0x1000) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_A }
				if (xb & 0x2000) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_B }
				if (xb & 0x4000) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_X }
				if (xb & 0x8000) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_Y }
				st.left_trigger = f32(xs.gamepad.left_trigger) / 255.0
				st.right_trigger = f32(xs.gamepad.right_trigger) / 255.0
				st.left_thumbstick_x = gi_norm_stick(xs.gamepad.thumb_lx, 7849)
				st.left_thumbstick_y = gi_norm_stick(xs.gamepad.thumb_ly, 7849)
				st.right_thumbstick_x = gi_norm_stick(xs.gamepad.thumb_rx, 8689)
				st.right_thumbstick_y = gi_norm_stick(xs.gamepad.thumb_ry, 8689)
				break
			}
		}
	}

	// 1b. PlayStation (DualShock 4 / DualSense) & Generic USB/BT gamepad via WinMM joyGetPosEx
	if !xinput_found && gi_joy_get_pos_ex != nil {
		for jid in u32(0) ..< 4 {
			ji := Joy_Info_Ex{dwSize = size_of(Joy_Info_Ex), dwFlags = 0xFF} // JOY_RETURNALL
			if gi_joy_get_pos_ex(jid, &ji) == 0 {
				jb := ji.dwButtons
				// DualShock 4 / DualSense HID button mapping: 0=Square(X), 1=Cross(A), 2=Circle(B), 3=Triangle(Y)
				if (jb & (1 << 0)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_X }
				if (jb & (1 << 1)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_A }
				if (jb & (1 << 2)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_B }
				if (jb & (1 << 3)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_Y }
				if (jb & (1 << 4)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_LEFT_SHOULDER }
				if (jb & (1 << 5)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_RIGHT_SHOULDER }
				if (jb & (1 << 6)) != 0 { st.left_trigger = 1.0 }
				if (jb & (1 << 7)) != 0 { st.right_trigger = 1.0 }
				if (jb & (1 << 8)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_VIEW }
				if (jb & (1 << 9)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_MENU }
				if (jb & (1 << 10)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_LEFT_THUMBSTICK }
				if (jb & (1 << 11)) != 0 { st.buttons |= GAMEINPUT_GAMEPAD_RIGHT_THUMBSTICK }
				if ji.dwPOV != 0xFFFF && ji.dwPOV < 36000 {
					if ji.dwPOV >= 31500 || ji.dwPOV <= 4500 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_UP }
					if ji.dwPOV >= 4500 && ji.dwPOV <= 13500 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_RIGHT }
					if ji.dwPOV >= 13500 && ji.dwPOV <= 22500 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_DOWN }
					if ji.dwPOV >= 22500 && ji.dwPOV <= 31500 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_LEFT }
				}
				lx := (f32(ji.dwXpos) - 32767.5) / 32767.5
				ly := -(f32(ji.dwYpos) - 32767.5) / 32767.5
				rx := (f32(ji.dwZpos) - 32767.5) / 32767.5
				ry := -(f32(ji.dwRpos) - 32767.5) / 32767.5
				if lx > 0.2 || lx < -0.2 { st.left_thumbstick_x = lx }
				if ly > 0.2 || ly < -0.2 { st.left_thumbstick_y = ly }
				if rx > 0.2 || rx < -0.2 { st.right_thumbstick_x = rx }
				if ry > 0.2 || ry < -0.2 { st.right_thumbstick_y = ry }
				break
			}
		}
	}

	// 2. Win32 keyboard fallback (WASD + Arrows + Enter/Space=A, Esc/Back=B, E=X, Y/F=Y)
	if gi_key_down(0x0D) || gi_key_down(0x20) { st.buttons |= GAMEINPUT_GAMEPAD_A } // Enter / Space
	if gi_key_down(0x1B) || gi_key_down(0x08) { st.buttons |= GAMEINPUT_GAMEPAD_B } // Esc / Backspace
	if gi_key_down('E') { st.buttons |= GAMEINPUT_GAMEPAD_X }
	if gi_key_down('Y') || gi_key_down('F') { st.buttons |= GAMEINPUT_GAMEPAD_Y }
	if gi_key_down('P') || gi_key_down('M') { st.buttons |= GAMEINPUT_GAMEPAD_MENU }
	if gi_key_down(0x09) { st.buttons |= GAMEINPUT_GAMEPAD_VIEW } // Tab
	if gi_key_down(0x26) { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_UP }    // Up
	if gi_key_down(0x28) { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_DOWN }  // Down
	if gi_key_down(0x25) { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_LEFT }  // Left
	if gi_key_down(0x27) { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_RIGHT } // Right
	if gi_key_down('Q') { st.buttons |= GAMEINPUT_GAMEPAD_LEFT_SHOULDER }
	if gi_key_down('R') { st.buttons |= GAMEINPUT_GAMEPAD_RIGHT_SHOULDER }
	if gi_key_down(0x10) { st.right_trigger = 1.0 } // Shift
	if gi_key_down(0x11) { st.left_trigger = 1.0 }  // Ctrl

	if gi_key_down('W') { st.left_thumbstick_y = 1.0 }
	if gi_key_down('S') { st.left_thumbstick_y = -1.0 }
	if gi_key_down('D') { st.left_thumbstick_x = 1.0 }
	if gi_key_down('A') { st.left_thumbstick_x = -1.0 }

	if gi_key_down('I') { st.right_thumbstick_y = 1.0 }
	if gi_key_down('K') { st.right_thumbstick_y = -1.0 }
	if gi_key_down('L') { st.right_thumbstick_x = 1.0 }
	if gi_key_down('J') { st.right_thumbstick_x = -1.0 }

	// 3. Optional automated menu progression for unattended boot tests
	if gi_auto_press_a {
		elapsed_ms := u64(time.duration_milliseconds(time.tick_since(gi_start_tick)))
		if elapsed_ms >= 3000 && elapsed_ms < 40000 {
			// Pass Text Size / Account / Legal / Intro: press A every 1.5s
			if ((elapsed_ms - 3000) % 1500) < 200 {
				st.buttons |= GAMEINPUT_GAMEPAD_A
			}
		} else if elapsed_ms >= 45000 && elapsed_ms < 60000 {
			// Rockstar Terms & Policies: Up, Up, Up, A (Privacy), Down, A (ToS), Down, A (Confirm), A
			t := elapsed_ms - 45000
			if t >= 500 && t < 700 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_UP }
			if t >= 1700 && t < 1900 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_UP }
			if t >= 2900 && t < 3100 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_UP }
			if t >= 4100 && t < 4300 { st.buttons |= GAMEINPUT_GAMEPAD_A }
			if t >= 5300 && t < 5500 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_DOWN }
			if t >= 6500 && t < 6700 { st.buttons |= GAMEINPUT_GAMEPAD_A }
			if t >= 7700 && t < 7900 { st.buttons |= GAMEINPUT_GAMEPAD_DPAD_DOWN }
			if t >= 8900 && t < 9100 { st.buttons |= GAMEINPUT_GAMEPAD_A }
			if t >= 10100 && t < 10300 { st.buttons |= GAMEINPUT_GAMEPAD_A }
		} else if elapsed_ms >= 60000 {
			// Main Menu -> Story Mode -> 3D World: press A every 2.0s
			if ((elapsed_ms - 60000) % 2000) < 200 {
				st.buttons |= GAMEINPUT_GAMEPAD_A
			}
		}
	}

	return st
}

// ---- IGameInputDevice ----
@(private) gid_add_ref :: proc "system" (d: ^GameInput_Device) -> u32 {
	context = hle_context()
	if d == nil { return 1 }
	return intrinsics.atomic_add(&d.refs, 1) + 1
}
@(private) gid_release :: proc "system" (d: ^GameInput_Device) -> u32 {
	context = hle_context()
	if d == nil { return 0 }
	v := intrinsics.atomic_sub(&d.refs, 1) - 1
	if v == 0 { intrinsics.atomic_store(&d.refs, 1) } // static singleton
	return max(v, 1)
}
@(private) gid_get_info :: proc "system" (_: ^GameInput_Device) -> ^GameInput_Device_Info {
	context = hle_context()
	return &gi_device_info
}
@(private) gid_get_status :: proc "system" (_: ^GameInput_Device) -> u32 {
	context = hle_context()
	return GAMEINPUT_DEVICE_CONNECTED | GAMEINPUT_DEVICE_INPUT_ENABLED
}
@(private) gid_get_battery :: proc "system" (_: ^GameInput_Device, st: ^GameInput_Battery_State) {
	context = hle_context()
	if st != nil {
		st^ = GameInput_Battery_State{max_charge_capacity = 1.0, remaining_capacity = 1.0, status = 4} // Wired
	}
}
@(private) gid_is_ff_on :: proc "system" (_: ^GameInput_Device, _: u32) -> bool {
	context = hle_context()
	return false
}
@(private) gid_noop :: proc "system" (_: ^GameInput_Device) { context = hle_context() }

GAMEINPUT_DEVICE_VTABLE := [22]rawptr {
	rawptr(rt_missing),     // 0 QueryInterface
	rawptr(gid_add_ref),    // 1 AddRef
	rawptr(gid_release),    // 2 Release
	rawptr(gid_get_info),   // 3 GetDeviceInfo
	rawptr(gid_get_status), // 4 GetDeviceStatus
	rawptr(gid_get_battery),// 5 GetBatteryState
	rawptr(rt_missing),     // 6 CreateForceFeedbackEffect
	rawptr(gid_is_ff_on),   // 7 IsForceFeedbackMotorPoweredOn
	rawptr(gid_noop),       // 8 SetForceFeedbackMotorGain
	rawptr(gid_noop),       // 9 SetHapticMotorState
	rawptr(gid_noop),       // 10 SetRumbleState
	rawptr(gid_noop),       // 11 SetInputSynchronizationState
	rawptr(gid_noop),       // 12 SendInputSynchronizationHint
	rawptr(gid_noop),       // 13 PowerOff
	rawptr(rt_missing),     // 14 CreateRawDeviceReport
	rawptr(rt_missing),     // 15 GetRawDeviceFeature
	rawptr(rt_missing),     // 16 SetRawDeviceFeature
	rawptr(rt_missing),     // 17 SendRawDeviceOutput
	rawptr(rt_missing),     // 18 SendRawDeviceOutputWithResponse
	rawptr(rt_missing),     // 19 ExecuteRawDeviceIoControl
	rawptr(rt_missing),     // 20 AcquireExclusiveRawDeviceAccess
	rawptr(rt_missing),     // 21 ReleaseExclusiveRawDeviceAccess
}

// ---- IGameInputReading ----
@(private) gir_add_ref :: proc "system" (r: ^GameInput_Reading) -> u32 {
	context = hle_context()
	if r == nil { return 0 }
	return intrinsics.atomic_add(&r.refs, 1) + 1
}
@(private) gir_release :: proc "system" (r: ^GameInput_Reading) -> u32 {
	context = hle_context()
	if r == nil { return 0 }
	left := intrinsics.atomic_sub(&r.refs, 1) - 1
	if left == 0 { free(r) }
	return left
}
@(private) gir_get_kind :: proc "system" (_: ^GameInput_Reading) -> u32 {
	context = hle_context()
	return GAMEINPUT_KIND_GAMEPAD | GAMEINPUT_KIND_UI_NAVIGATION
}
@(private) gir_get_seq :: proc "system" (r: ^GameInput_Reading, _: u32) -> u64 {
	context = hle_context()
	return r.seq if r != nil else 0
}
@(private) gir_get_ts :: proc "system" (r: ^GameInput_Reading) -> u64 {
	context = hle_context()
	return r.ts if r != nil else 0
}
@(private) gir_get_device :: proc "system" (_: ^GameInput_Reading, out: ^^GameInput_Device) {
	context = hle_context()
	gi_ensure_init()
	if out != nil {
		_ = gid_add_ref(&gi_device)
		out^ = &gi_device
	}
}
@(private) gir_false :: proc "system" (_: ^GameInput_Reading) -> bool { context = hle_context(); return false }
@(private) gir_zero_u32 :: proc "system" (_: ^GameInput_Reading) -> u32 { context = hle_context(); return 0 }
@(private) gir_get_gamepad :: proc "system" (r: ^GameInput_Reading, out: ^GameInput_Gamepad_State) -> bool {
	context = hle_context()
	if r == nil || out == nil { return false }
	out^ = r.gamepad
	return true
}
@(private) gir_get_ui_nav :: proc "system" (r: ^GameInput_Reading, out: ^GameInput_Ui_Nav_State) -> bool {
	context = hle_context()
	if r == nil || out == nil { return false }
	ui: u32 = 0
	b := r.gamepad.buttons
	if (b & GAMEINPUT_GAMEPAD_MENU) != 0 { ui |= 0x0001 }
	if (b & GAMEINPUT_GAMEPAD_VIEW) != 0 { ui |= 0x0002 }
	if (b & GAMEINPUT_GAMEPAD_A) != 0 { ui |= 0x0004 }
	if (b & GAMEINPUT_GAMEPAD_B) != 0 { ui |= 0x0008 }
	if (b & GAMEINPUT_GAMEPAD_DPAD_UP) != 0 { ui |= 0x0010 }
	if (b & GAMEINPUT_GAMEPAD_DPAD_DOWN) != 0 { ui |= 0x0020 }
	if (b & GAMEINPUT_GAMEPAD_DPAD_LEFT) != 0 { ui |= 0x0040 }
	if (b & GAMEINPUT_GAMEPAD_DPAD_RIGHT) != 0 { ui |= 0x0080 }
	out.buttons = ui
	return true
}

GAMEINPUT_READING_VTABLE := [25]rawptr {
	rawptr(rt_missing),     // 0 QueryInterface
	rawptr(gir_add_ref),    // 1 AddRef
	rawptr(gir_release),    // 2 Release
	rawptr(gir_get_kind),   // 3 GetInputKind
	rawptr(gir_get_seq),    // 4 GetSequenceNumber
	rawptr(gir_get_ts),     // 5 GetTimestamp
	rawptr(gir_get_device), // 6 GetDevice
	rawptr(gir_false),      // 7 GetRawReport
	rawptr(gir_zero_u32),   // 8 GetControllerAxisCount
	rawptr(gir_zero_u32),   // 9 GetControllerAxisState
	rawptr(gir_zero_u32),   // 10 GetControllerButtonCount
	rawptr(gir_zero_u32),   // 11 GetControllerButtonState
	rawptr(gir_zero_u32),   // 12 GetControllerSwitchCount
	rawptr(gir_zero_u32),   // 13 GetControllerSwitchState
	rawptr(gir_zero_u32),   // 14 GetKeyCount
	rawptr(gir_zero_u32),   // 15 GetKeyState
	rawptr(gir_false),      // 16 GetMouseState
	rawptr(gir_zero_u32),   // 17 GetTouchCount
	rawptr(gir_zero_u32),   // 18 GetTouchState
	rawptr(gir_false),      // 19 GetMotionState
	rawptr(gir_false),      // 20 GetArcadeStickState
	rawptr(gir_false),      // 21 GetFlightStickState
	rawptr(gir_get_gamepad),// 22 GetGamepadState
	rawptr(gir_false),      // 23 GetRacingWheelState
	rawptr(gir_get_ui_nav), // 24 GetUiNavigationState
}

@(private)
gi_alloc_reading :: proc() -> ^GameInput_Reading {
	r := new(GameInput_Reading)
	r^ = GameInput_Reading {
		vtable  = raw_data(GAMEINPUT_READING_VTABLE[:]),
		refs    = 1,
		seq     = intrinsics.atomic_add(&gi_seq, 1),
		ts      = u64(time.tick_now()._nsec / 1000),
		gamepad = gi_sample_gamepad(),
	}
	return r
}

// ---- IGameInput ----
@(private) gi_add_ref :: proc "system" (t: ^GameInput_Object) -> u32 {
	context = hle_context()
	return intrinsics.atomic_add(&t.refs, 1) + 1
}
@(private) gi_release :: proc "system" (t: ^GameInput_Object) -> u32 {
	context = hle_context()
	left := intrinsics.atomic_sub(&t.refs, 1) - 1
	if left == 0 { free(t) }
	return left
}
@(private) gi_get_cur_ts :: proc "system" (_: ^GameInput_Object) -> u64 {
	context = hle_context()
	return u64(time.tick_now()._nsec / 1000)
}
@(private) gi_get_cur_reading :: proc "system" (_: ^GameInput_Object, kind: u32, _: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if out == nil { return E_INVALIDARG }
	if kind != 0 && (kind & (GAMEINPUT_KIND_GAMEPAD | GAMEINPUT_KIND_UI_NAVIGATION)) == 0 {
		out^ = nil
		return GAMEINPUT_READING_NOT_FOUND
	}
	out^ = rawptr(gi_alloc_reading())
	return S_OK
}
@(private) gi_next_reading :: proc "system" (_: ^GameInput_Object, _: rawptr, _: u32, _: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if out != nil { out^ = nil }
	return GAMEINPUT_READING_NOT_FOUND
}
@(private) gi_prev_reading :: proc "system" (_: ^GameInput_Object, _: rawptr, _: u32, _: rawptr, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if out != nil { out^ = nil }
	return GAMEINPUT_READING_NOT_FOUND
}
@(private) gi_reg_reading_cb :: proc "system" (_: ^GameInput_Object, _: rawptr, _: u32, _: f32, _: rawptr, _: rawptr, tok: ^u64) -> HRESULT {
	context = hle_context()
	if uintptr(tok) > 0x10000 { tok^ = next_token() }
	return S_OK
}

Device_Callback_Proc :: #type proc "system" (
	token: u64,
	ctx: rawptr,
	device: ^GameInput_Device,
	timestamp: u64,
	current_status: u32,
	previous_status: u32,
)

@(private) gi_reg_dev_cb :: proc "system" (
	_: ^GameInput_Object,
	_: rawptr,
	input_kind: u32,
	status_filter: u32,
	enum_kind: u32,
	cb_ctx: rawptr,
	cb_fn: rawptr,
	tok: ^u64,
) -> HRESULT {
	context = hle_context()
	gi_ensure_init()
	t := next_token()
	if uintptr(tok) > 0x10000 { tok^ = t }
	if cb_fn != nil && enum_kind != 0 && (input_kind == 0 || (input_kind & (GAMEINPUT_KIND_GAMEPAD | GAMEINPUT_KIND_UI_NAVIGATION)) != 0) && (status_filter == 0 || (status_filter & GAMEINPUT_DEVICE_CONNECTED) != 0) {
		cb := cast(Device_Callback_Proc)cb_fn
		ts := u64(time.tick_now()._nsec / 1000)
		cb(t, cb_ctx, &gi_device, ts, GAMEINPUT_DEVICE_CONNECTED | GAMEINPUT_DEVICE_INPUT_ENABLED, 0)
	}
	return S_OK
}
@(private) gi_reg_other_cb :: proc "system" (_: ^GameInput_Object, _: rawptr, _: rawptr, _: rawptr, tok: ^u64) -> HRESULT {
	context = hle_context()
	if uintptr(tok) > 0x10000 { tok^ = next_token() }
	return S_OK
}
@(private) gi_unreg_cb :: proc "system" (_: ^GameInput_Object, _: u64, _: u64) -> bool { context = hle_context(); return true }
@(private) gi_stop_cb :: proc "system" (_: ^GameInput_Object, _: u64) { context = hle_context() }
@(private) gi_find_device_by_id :: proc "system" (_: ^GameInput_Object, _: rawptr, out: ^^GameInput_Device) -> HRESULT {
	context = hle_context()
	gi_ensure_init()
	if out == nil { return E_INVALIDARG }
	_ = gid_add_ref(&gi_device)
	out^ = &gi_device
	return S_OK
}
@(private) gi_set_focus_policy :: proc "system" (_: ^GameInput_Object, _: u32) { context = hle_context() }

GAMEINPUT_VTABLE := [22]rawptr {
	rawptr(rt_missing),          // 0 QueryInterface
	rawptr(gi_add_ref),          // 1 AddRef
	rawptr(gi_release),          // 2 Release
	rawptr(gi_get_cur_ts),       // 3 GetCurrentTimestamp
	rawptr(gi_get_cur_reading),  // 4 GetCurrentReading
	rawptr(gi_next_reading),     // 5 GetNextReading
	rawptr(gi_prev_reading),     // 6 GetPreviousReading
	rawptr(rt_missing),          // 7 GetTemporalReading
	rawptr(gi_reg_reading_cb),   // 8 RegisterReadingCallback
	rawptr(gi_reg_dev_cb),       // 9 RegisterDeviceCallback
	rawptr(gi_reg_other_cb),     // 10 RegisterSystemButtonCallback
	rawptr(gi_reg_other_cb),     // 11 RegisterKeyboardLayoutCallback
	rawptr(gi_stop_cb),          // 12 StopCallback
	rawptr(gi_unreg_cb),         // 13 UnregisterCallback
	rawptr(rt_missing),          // 14 CreateDispatcher
	rawptr(rt_missing),          // 15 CreateAggregateDevice
	rawptr(gi_find_device_by_id),// 16 FindDeviceFromId
	rawptr(rt_missing),          // 17 FindDeviceFromObject
	rawptr(rt_missing),          // 18 FindDeviceFromPlatformHandle
	rawptr(rt_missing),          // 19 FindDeviceFromPlatformString
	rawptr(rt_missing),          // 20 EnableOemDeviceSupport
	rawptr(gi_set_focus_policy), // 21 SetFocusPolicy
}

GameInputCreate :: proc "system" (out: ^^GameInput_Object) -> HRESULT {
	context = hle_context()
	gi_ensure_init()
	if out == nil { return E_INVALIDARG }
	obj := new(GameInput_Object)
	obj^ = GameInput_Object{vtable = raw_data(GAMEINPUT_VTABLE[:]), refs = 1}
	out^ = obj
	return S_OK
}

GAMEINPUT_DLLS := [?]string{"gameinput.dll"}
GAMEINPUT_EXPORTS := [?]Hle_Export{{name = "#1", address = uintptr(rawptr(GameInputCreate))}}
