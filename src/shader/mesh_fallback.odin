package vasperty_shader

import "core:strings"

// Mesh Shader -> Compute + Indirect-Draw Vertex Fallback Engine
// Enables full Xbox Series Mesh Shader (MS) execution on GPUs without hardware
// D3D12 Mesh Shaders (Intel UHD / Iris Xe Integrated GPUs, NVIDIA Pascal/GTX 10-series).

D3D12_DRAW_INDEXED_ARGS_BYTES :: u32(20) // IndexCount, InstanceCount, StartIndex, BaseVertex, StartInstance

Mesh_Fallback_Plan :: struct {
	max_vertices:        u32,
	max_primitives:      u32,
	indices_per_prim:    u32, // 3 for triangles, 2 for lines, 1 for points
	threads_per_group:   u32,
	lds_bytes:           u32,
	attr_count:          u32, // position + output params
	vertex_stride_bytes: u32,
	vertex_buffer_bytes: u32,
	index_buffer_bytes:  u32,
	indirect_args_bytes: u32,
	total_scratch_bytes: u32,
	target_wave_size:    u8,
}

align_up_u32 :: proc "contextless" (v, align: u32) -> u32 {
	if align <= 1 {
		return v
	}
	return (v + align - 1) & ~(align - 1)
}

// Computes the exact per-meshlet scratch UAV layout for Compute-emulated Mesh Shaders.
mesh_fallback_plan :: proc(mio: ^Mesh_Io, target_wave: Target_Wave_Mode) -> Mesh_Fallback_Plan {
	max_v := max(mio.max_vertices, u32(1))
	max_p := max(mio.max_primitives, u32(1))
	ip := u32(3)
	if mio.topology == 1 {
		ip = 1 // points
	} else if mio.topology == 2 {
		ip = 2 // lines
	}
	attrs := u32(1 + len(mio.outputs)) // SV_Position + TEXCOORD params
	v_stride := align_up_u32(attrs * 16, 16)
	v_bytes := align_up_u32(max_v * v_stride, 256)
	i_bytes := align_up_u32(max_p * ip * 4, 256)
	a_bytes := align_up_u32(D3D12_DRAW_INDEXED_ARGS_BYTES, 256)
	thr := max(mio.threads, u32(target_wave_lanes(target_wave)))
	return Mesh_Fallback_Plan{
		max_vertices        = max_v,
		max_primitives      = max_p,
		indices_per_prim    = ip,
		threads_per_group   = thr,
		lds_bytes           = mio.lds_bytes,
		attr_count          = attrs,
		vertex_stride_bytes = v_stride,
		vertex_buffer_bytes = v_bytes,
		index_buffer_bytes  = i_bytes,
		indirect_args_bytes = a_bytes,
		total_scratch_bytes = v_bytes + i_bytes + a_bytes,
		target_wave_size    = target_wave_lanes(target_wave),
	}
}

// Emits a valid SM 6.6 pass-through Vertex Shader (`vs_6_6`) DXBC container that fetches
// SV_VertexID from the Compute-emulated meshlet vertex scratch SRV (t0, space0) and
// outputs SV_Position + `param_count` float4 TEXCOORD attributes.
emit_mesh_passthrough_vs :: proc(param_count: u32, wave_mode := Target_Wave_Mode.Wave16) -> Host_Shader {
	s := shader_create(false)
	defer shader_destroy(&s)
	s.flags |= DXIL_FLAG_RAW_BUFFERS
	if wave_mode != .Auto {
		s.has_wave = true
		s.wave_size = u32(target_wave_lanes(wave_mode))
	}

	// Input: SV_VertexID (system value kind=1)
	append(&s.inputs, Sig_Element{
		name    = strings.clone("SV_VertexID"),
		kind    = 1,
		comp    = 1, // uint32
		has_row = false,
		cols    = 1,
		usage   = 1,
	})
	// Output 0: SV_Position (kind=3, row=0)
	append(&s.outputs, Sig_Element{
		name    = strings.clone("SV_Position"),
		kind    = 3,
		comp    = 9, // float32
		has_row = true,
		row     = 0,
		cols    = 4,
		usage   = 0xF,
	})
	clamped_params := min(param_count, u32(16))
	for p in u32(0) ..< clamped_params {
		append(&s.outputs, Sig_Element{
			name    = strings.clone("TEXCOORD"),
			index   = p,
			kind    = 0,
			comp    = 9,
			has_row = true,
			row     = p + 1,
			cols    = 4,
			usage   = 0xF,
		})
	}

	b := bc_new_block(&s.m)
	// Load SV_VertexID -> vertex byte offset = vid * stride
	vid := shader_op(&s, b, "vertexId", .Read_None, s.t.i32, 93, {})
	stride := (1 + clamped_params) * 16
	base_off := bc_bin(&s.m, b, .Mul, vid, bc_i32(&s.m, stride))

	// Bind raw SRV t0 (meshlet vertex scratch buffer)
	srv_h := shader_root_srv_handle(&s, 0)

	// Load SV_Position (4x f32) and storeOutput.f32
	pos_ret := shader_op(&s, b, "rawBufferLoad.f32", .Read_Only, s.t.res_ret, 139, {
		srv_h, base_off, bc_undef(&s.m, s.t.i32), bc_i8(&s.m, 0xF), bc_i32(&s.m, 4),
	})
	for ch in u8(0) ..< 4 {
		fv := bc_extract(&s.m, b, pos_ret, u32(ch))
		shader_op(&s, b, "storeOutput.f32", .No_Unwind, s.t.void_ty, 5, {
			bc_i32(&s.m, 0), bc_i32(&s.m, 0), bc_i8(&s.m, ch), fv,
		})
	}

	// Load & forward each TEXCOORD float4 attribute
	for p in u32(0) ..< clamped_params {
		off_p := bc_bin(&s.m, b, .Add, base_off, bc_i32(&s.m, (p + 1) * 16))
		attr_ret := shader_op(&s, b, "rawBufferLoad.f32", .Read_Only, s.t.res_ret, 139, {
			srv_h, off_p, bc_undef(&s.m, s.t.i32), bc_i8(&s.m, 0xF), bc_i32(&s.m, 4),
		})
		for ch in u8(0) ..< 4 {
			fv := bc_extract(&s.m, b, attr_ret, u32(ch))
			shader_op(&s, b, "storeOutput.f32", .No_Unwind, s.t.void_ty, 5, {
				bc_i32(&s.m, p + 1), bc_i32(&s.m, 0), bc_i8(&s.m, ch), fv,
			})
		}
	}

	bc_terminate(&s.m, b, Term{kind = .Ret})

	hs: Host_Shader
	hs.stage = .Vs
	hs.dxil = shader_finish(&s)
	hs.root_srvs = make([dynamic]u8, 1)
	hs.root_srvs[0] = 0
	hs.target_wave_size = target_wave_lanes(wave_mode)
	return hs
}
