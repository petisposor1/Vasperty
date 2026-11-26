package vasperty_gpu

import "base:intrinsics"
import "core:sync"
import vasperty_shader "vasperty:shader"

// =========================================================================
// Lazy Host D3D12 RootSignature + PipelineState Compilation
// =========================================================================

@(private)
IID_ID3D12RootSignature_G := guid(0xc54a6b66, 0x72df, 0x4ee8, {0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14})
@(private)
IID_ID3D12PipelineState_G := guid(0x765a30f3, 0xf624, 0x4c6f, {0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45})

@(private)
D3D_ROOT_SIGNATURE_VERSION_1_1 :: u32(0x2)
@(private)
D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED :: u32(0x400)
@(private)
D3D12_ROOT_SIGNATURE_FLAG_SAMPLER_HEAP_DIRECTLY_INDEXED :: u32(0x800)

@(private)
D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS :: u32(1)
@(private)
D3D12_ROOT_PARAMETER_TYPE_CBV :: u32(2)
@(private)
D3D12_ROOT_PARAMETER_TYPE_SRV :: u32(3)
@(private)
D3D12_ROOT_PARAMETER_TYPE_UAV :: u32(4)

@(private)
D3D12_SHADER_VISIBILITY_ALL :: u32(0)
@(private)
D3D12_SHADER_VISIBILITY_VERTEX :: u32(1)
@(private)
D3D12_SHADER_VISIBILITY_PIXEL :: u32(5)

@(private)
D3D12_ROOT_DESCRIPTOR_TABLE1 :: struct {
	NumDescriptorRanges: u32,
	pDescriptorRanges:   rawptr,
}

@(private)
D3D12_ROOT_CONSTANTS :: struct {
	ShaderRegister: u32,
	RegisterSpace:  u32,
	Num32BitValues: u32,
}

@(private)
D3D12_ROOT_DESCRIPTOR1 :: struct {
	ShaderRegister: u32,
	RegisterSpace:  u32,
	Flags:          u32,
}

@(private)
D3D12_ROOT_PARAMETER1 :: struct {
	ParameterType:    u32,
	using _:          struct #raw_union {
		DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE1,
		Constants:       D3D12_ROOT_CONSTANTS,
		Descriptor:      D3D12_ROOT_DESCRIPTOR1,
	},
	ShaderVisibility: u32,
}

#assert(size_of(D3D12_ROOT_PARAMETER1) == 32)

@(private)
D3D12_STATIC_SAMPLER_DESC :: struct {
	Filter:           u32,
	AddressU:         u32,
	AddressV:         u32,
	AddressW:         u32,
	MipLODBias:       f32,
	MaxAnisotropy:    u32,
	ComparisonFunc:   u32,
	BorderColor:      u32,
	MinLOD:           f32,
	MaxLOD:           f32,
	ShaderRegister:   u32,
	RegisterSpace:    u32,
	ShaderVisibility: u32,
}

#assert(size_of(D3D12_STATIC_SAMPLER_DESC) == 52)

@(private)
D3D12_ROOT_SIGNATURE_DESC1 :: struct {
	NumParameters:     u32,
	pParameters:       rawptr,
	NumStaticSamplers: u32,
	pStaticSamplers:   rawptr,
	Flags:             u32,
}

#assert(size_of(D3D12_ROOT_SIGNATURE_DESC1) == 40)

@(private)
D3D12_VERSIONED_ROOT_SIGNATURE_DESC :: struct {
	Version:  u32,
	Desc_1_1: D3D12_ROOT_SIGNATURE_DESC1,
}

#assert(size_of(D3D12_VERSIONED_ROOT_SIGNATURE_DESC) == 48)

@(private)
D3D12_SHADER_BYTECODE :: struct {
	pShaderBytecode: rawptr,
	BytecodeLength:  uint,
}

@(private)
D3D12_STREAM_OUTPUT_DESC :: struct {
	pSODeclaration:   rawptr,
	NumEntries:       u32,
	pBufferStrides:   rawptr,
	NumStrides:       u32,
	RasterizedStream: u32,
}

@(private)
D3D12_RENDER_TARGET_BLEND_DESC :: struct {
	BlendEnable:           i32,
	LogicOpEnable:         i32,
	SrcBlend:              u32,
	DestBlend:             u32,
	BlendOp:               u32,
	SrcBlendAlpha:         u32,
	DestBlendAlpha:        u32,
	BlendOpAlpha:          u32,
	LogicOp:               u32,
	RenderTargetWriteMask: u8,
}

@(private)
D3D12_BLEND_DESC :: struct {
	AlphaToCoverageEnable:  i32,
	IndependentBlendEnable: i32,
	RenderTarget:           [8]D3D12_RENDER_TARGET_BLEND_DESC,
}

@(private)
D3D12_RASTERIZER_DESC :: struct {
	FillMode:              u32,
	CullMode:              u32,
	FrontCounterClockwise: i32,
	DepthBias:             i32,
	DepthBiasClamp:        f32,
	SlopeScaledDepthBias:  f32,
	DepthClipEnable:       i32,
	MultisampleEnable:     i32,
	AntialiasedLineEnable: i32,
	ForcedSampleCount:     u32,
	ConservativeRaster:    u32,
}

@(private)
D3D12_DEPTH_STENCILOP_DESC :: struct {
	StencilFailOp:      u32,
	StencilDepthFailOp: u32,
	StencilPassOp:      u32,
	StencilFunc:        u32,
}

@(private)
D3D12_DEPTH_STENCIL_DESC :: struct {
	DepthEnable:      i32,
	DepthWriteMask:   u32,
	DepthFunc:        u32,
	StencilEnable:    i32,
	StencilReadMask:  u8,
	StencilWriteMask: u8,
	FrontFace:        D3D12_DEPTH_STENCILOP_DESC,
	BackFace:         D3D12_DEPTH_STENCILOP_DESC,
}

@(private)
D3D12_INPUT_LAYOUT_DESC :: struct {
	pInputElementDescs: rawptr,
	NumElements:        u32,
}

@(private)
D3D12_CACHED_PIPELINE_STATE :: struct {
	pCachedBlob:           rawptr,
	CachedBlobSizeInBytes: uint,
}

@(private)
D3D12_GRAPHICS_PIPELINE_STATE_DESC :: struct {
	pRootSignature:        rawptr,
	VS:                    D3D12_SHADER_BYTECODE,
	PS:                    D3D12_SHADER_BYTECODE,
	DS:                    D3D12_SHADER_BYTECODE,
	HS:                    D3D12_SHADER_BYTECODE,
	GS:                    D3D12_SHADER_BYTECODE,
	StreamOutput:          D3D12_STREAM_OUTPUT_DESC,
	BlendState:            D3D12_BLEND_DESC,
	SampleMask:            u32,
	RasterizerState:       D3D12_RASTERIZER_DESC,
	DepthStencilState:     D3D12_DEPTH_STENCIL_DESC,
	InputLayout:           D3D12_INPUT_LAYOUT_DESC,
	IBStripCutValue:       u32,
	PrimitiveTopologyType: u32,
	NumRenderTargets:      u32,
	RTVFormats:            [8]u32,
	DSVFormat:             u32,
	SampleDesc:            DXGI_SAMPLE_DESC,
	NodeMask:              u32,
	CachedPSO:             D3D12_CACHED_PIPELINE_STATE,
	Flags:                 u32,
}

#assert(size_of(D3D12_GRAPHICS_PIPELINE_STATE_DESC) == 656)

@(private)
D3D12_COMPUTE_PIPELINE_STATE_DESC :: struct {
	pRootSignature: rawptr,
	CS:             D3D12_SHADER_BYTECODE,
	NodeMask:       u32,
	CachedPSO:      D3D12_CACHED_PIPELINE_STATE,
	Flags:          u32,
}

#assert(size_of(D3D12_COMPUTE_PIPELINE_STATE_DESC) == 56)

@(private)
Pso_Dev_Vtbl :: struct {
	_pad0:                       [10]rawptr,                                              // 0..9
	CreateGraphicsPipelineState: proc "system" (rawptr, ^D3D12_GRAPHICS_PIPELINE_STATE_DESC, ^Iid, ^rawptr) -> HRESULT, // 10
	CreateComputePipelineState:  proc "system" (rawptr, ^D3D12_COMPUTE_PIPELINE_STATE_DESC, ^Iid, ^rawptr) -> HRESULT,  // 11
	_pad1:                       [4]rawptr,                                               // 12..15
	CreateRootSignature:         proc "system" (rawptr, u32, rawptr, uint, ^Iid, ^rawptr) -> HRESULT,                   // 16
}

@(private)
D3D_Blob_Vtbl :: struct {
	QueryInterface:   rawptr,
	AddRef:           rawptr,
	Release:          proc "system" (rawptr) -> u32,
	GetBufferPointer: proc "system" (rawptr) -> rawptr,
	GetBufferSize:    proc "system" (rawptr) -> uint,
}

@(private)
append_shader_root_bindings :: proc(
	hs: ^vasperty_shader.Host_Shader,
	vis: u32,
	params: ^[dynamic]D3D12_ROOT_PARAMETER1,
	samplers: ^[dynamic]D3D12_STATIC_SAMPLER_DESC,
	bindings: ^[dynamic]Host_Root_Binding,
) {
	add_unique_desc :: proc(params: ^[dynamic]D3D12_ROOT_PARAMETER1, ptype: u32, reg: u32, space: u32, vis: u32) -> u32 {
		for &existing, idx in params^ {
			if existing.ParameterType == ptype &&
			   existing.Descriptor.ShaderRegister == reg &&
			   existing.Descriptor.RegisterSpace == space &&
			   existing.ShaderVisibility == vis {
				return u32(idx)
			}
		}
		idx := u32(len(params^))
		append(params, D3D12_ROOT_PARAMETER1{
			ParameterType    = ptype,
			Descriptor       = D3D12_ROOT_DESCRIPTOR1{ShaderRegister = reg, RegisterSpace = space},
			ShaderVisibility = vis,
		})
		return idx
	}

	for r in hs.root_cbvs {
		pidx := add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_CBV, u32(r), vasperty_shader.ROOT_CBV_SPACE, vis)
		append(bindings, Host_Root_Binding{param_idx = pidx, kind = 0, slot = r})
	}
	for r in hs.root_srvs {
		pidx := add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_SRV, u32(r), vasperty_shader.ROOT_CBV_SPACE, vis)
		append(bindings, Host_Root_Binding{param_idx = pidx, kind = 1, slot = r})
	}
	for r in hs.root_uavs {
		pidx := add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_UAV, u32(r), vasperty_shader.ROOT_CBV_SPACE, vis)
		append(bindings, Host_Root_Binding{param_idx = pidx, kind = 2, slot = r})
	}
	if hs.memory {
		_ = add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_SRV, 0, vasperty_shader.MEMORY_SPACE, D3D12_SHADER_VISIBILITY_ALL)
	}
	if hs.memory_writes {
		_ = add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_UAV, 0, vasperty_shader.MEMORY_SPACE, D3D12_SHADER_VISIBILITY_ALL)
	}
	if hs.view_addresses {
		_ = add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_SRV, 1, vasperty_shader.MEMORY_SPACE, D3D12_SHADER_VISIBILITY_ALL)
	}
	if hs.view_marks {
		_ = add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_SRV, 2, vasperty_shader.MEMORY_SPACE, D3D12_SHADER_VISIBILITY_ALL)
		_ = add_unique_desc(params, D3D12_ROOT_PARAMETER_TYPE_UAV, 1, vasperty_shader.MEMORY_SPACE, D3D12_SHADER_VISIBILITY_ALL)
	}
	for ss, idx in hs.static_samplers {
		append(samplers, D3D12_STATIC_SAMPLER_DESC{
			Filter           = sampler_filter_for_host(ss.filter, false),
			AddressU         = ss.address[0],
			AddressV         = ss.address[1],
			AddressW         = ss.address[2],
			MipLODBias       = ss.mip_lod_bias,
			MaxAnisotropy    = max(ss.max_anisotropy, u32(1)),
			ComparisonFunc   = ss.comparison if (ss.comparison >= 1 && ss.comparison <= 8) else 1,
			BorderColor      = ss.border % 3,
			MinLOD           = ss.min_lod,
			MaxLOD           = ss.max_lod,
			ShaderRegister   = u32(idx),
			RegisterSpace    = vasperty_shader.SAMPLER_SPACE,
			ShaderVisibility = vis,
		})
	}
}

@(private)
build_host_root_signature :: proc(hdev: rawptr, p: ^Console_Pipeline) -> rawptr {
	dlls := ensure_d3d12_dlls()
	if dlls.serialize_vrs == nil {
		return nil
	}

	p.vs_ud_param = -1
	p.vs_ud_dwords = 0
	p.ps_ud_param = -1
	p.ps_ud_dwords = 0
	clear(&p.root_bindings)

	params := make([dynamic]D3D12_ROOT_PARAMETER1, 0, 12, context.temp_allocator)
	samplers := make([dynamic]D3D12_STATIC_SAMPLER_DESC, 0, 16, context.temp_allocator)

	if p.is_compute {
		ud := min(vasperty_shader.host_shader_user_data_dwords(&p.cs_shader), u32(64))
		if ud > 0 {
			p.vs_ud_param = i32(len(params))
			p.vs_ud_dwords = ud
			append(&params, D3D12_ROOT_PARAMETER1{
				ParameterType    = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS,
				Constants        = D3D12_ROOT_CONSTANTS{ShaderRegister = 0, RegisterSpace = vasperty_shader.USER_DATA_SPACE, Num32BitValues = ud},
				ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL,
			})
		}
		append_shader_root_bindings(&p.cs_shader, D3D12_SHADER_VISIBILITY_ALL, &params, &samplers, &p.root_bindings)
	} else {
		vs_ud := min(vasperty_shader.host_shader_user_data_dwords(&p.vs_shader), u32(64))
		if vs_ud > 0 {
			p.vs_ud_param = i32(len(params))
			p.vs_ud_dwords = vs_ud
			append(&params, D3D12_ROOT_PARAMETER1{
				ParameterType    = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS,
				Constants        = D3D12_ROOT_CONSTANTS{ShaderRegister = 0, RegisterSpace = vasperty_shader.USER_DATA_SPACE, Num32BitValues = vs_ud},
				ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX,
			})
		}
		if len(p.ps_shader.dxil) > 0 {
			ps_ud := min(vasperty_shader.host_shader_user_data_dwords(&p.ps_shader), u32(64))
			if ps_ud > 0 {
				p.ps_ud_param = i32(len(params))
				p.ps_ud_dwords = ps_ud
				append(&params, D3D12_ROOT_PARAMETER1{
					ParameterType    = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS,
					Constants        = D3D12_ROOT_CONSTANTS{ShaderRegister = 0, RegisterSpace = vasperty_shader.USER_DATA_SPACE, Num32BitValues = ps_ud},
					ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL,
				})
			}
		}
		append_shader_root_bindings(&p.vs_shader, D3D12_SHADER_VISIBILITY_VERTEX, &params, &samplers, &p.root_bindings)
		if len(p.ps_shader.dxil) > 0 {
			append_shader_root_bindings(&p.ps_shader, D3D12_SHADER_VISIBILITY_PIXEL, &params, &samplers, &p.root_bindings)
		}
	}

	rs_flags := D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED | D3D12_ROOT_SIGNATURE_FLAG_SAMPLER_HEAP_DIRECTLY_INDEXED
	if !p.is_compute {
		rs_flags |= 0x1 // D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT
	}
	vrs := D3D12_VERSIONED_ROOT_SIGNATURE_DESC{
		Version = D3D_ROOT_SIGNATURE_VERSION_1_1,
		Desc_1_1 = D3D12_ROOT_SIGNATURE_DESC1{
			NumParameters     = u32(len(params)),
			pParameters       = &params[0] if len(params) > 0 else nil,
			NumStaticSamplers = u32(len(samplers)),
			pStaticSamplers   = &samplers[0] if len(samplers) > 0 else nil,
			Flags             = rs_flags,
		},
	}

	blob: rawptr
	err_blob: rawptr
	hr := dlls.serialize_vrs(&vrs, &blob, &err_blob)
	if err_blob != nil {
		com_release(err_blob)
		err_blob = nil
	}
	if hr < 0 || blob == nil {
		return nil
	}
	defer com_release(blob)

	bvt := (cast(^^D3D_Blob_Vtbl)blob)^
	buf_ptr := bvt.GetBufferPointer(blob)
	buf_len := bvt.GetBufferSize(blob)
	if buf_ptr == nil || buf_len == 0 {
		return nil
	}

	dvt := (cast(^^Pso_Dev_Vtbl)hdev)^
	rs_iid := IID_ID3D12RootSignature_G
	root_sig: rawptr
	if dvt.CreateRootSignature(hdev, 0, buf_ptr, buf_len, &rs_iid, &root_sig) < 0 || root_sig == nil {
		return nil
	}
	return root_sig
}

@(private)
default_graphics_pso_desc :: proc "contextless" (p: ^Console_Pipeline, root_sig: rawptr) -> D3D12_GRAPHICS_PIPELINE_STATE_DESC {
	desc := D3D12_GRAPHICS_PIPELINE_STATE_DESC{
		pRootSignature = root_sig,
		SampleMask     = 0xFFFF_FFFF,
		RasterizerState = D3D12_RASTERIZER_DESC{
			FillMode        = 3, // D3D12_FILL_MODE_SOLID
			CullMode        = 1, // D3D12_CULL_MODE_NONE
			DepthClipEnable = 1,
		},
		DepthStencilState = D3D12_DEPTH_STENCIL_DESC{
			DepthEnable      = 0,
			DepthWriteMask   = 0,
			DepthFunc        = 8, // D3D12_COMPARISON_FUNC_ALWAYS
			StencilReadMask  = 0xFF,
			StencilWriteMask = 0xFF,
			FrontFace        = {1, 1, 1, 8},
			BackFace         = {1, 1, 1, 8},
		},
		PrimitiveTopologyType = p.topology_type if (p.topology_type >= 1 && p.topology_type <= 4) else 3,
		SampleDesc            = DXGI_SAMPLE_DESC{Count = 1, Quality = 0},
	}

	for i in 0 ..< 8 {
		desc.BlendState.RenderTarget[i] = D3D12_RENDER_TARGET_BLEND_DESC{
			SrcBlend              = 2, // D3D12_BLEND_ONE
			DestBlend             = 1, // D3D12_BLEND_ZERO
			BlendOp               = 1, // D3D12_BLEND_OP_ADD
			SrcBlendAlpha         = 2, // D3D12_BLEND_ONE
			DestBlendAlpha        = 1, // D3D12_BLEND_ZERO
			BlendOpAlpha          = 1, // D3D12_BLEND_OP_ADD
			LogicOp               = 4, // D3D12_LOGIC_OP_NOOP
			RenderTargetWriteMask = 0xF,
		}
	}

	if p.has_blend {
		b := p.blend_desc
		for i in 0 ..< 8 {
			rt := &b.RenderTarget[i]
			if rt.SrcBlend == 0 { rt.SrcBlend = 2 }
			if rt.DestBlend == 0 { rt.DestBlend = 1 }
			if rt.BlendOp == 0 || rt.BlendOp > 5 { rt.BlendOp = 1 }
			if rt.SrcBlendAlpha == 0 { rt.SrcBlendAlpha = 2 }
			if rt.DestBlendAlpha == 0 { rt.DestBlendAlpha = 1 }
			if rt.BlendOpAlpha == 0 || rt.BlendOpAlpha > 5 { rt.BlendOpAlpha = 1 }
			if rt.LogicOp > 15 { rt.LogicOp = 4 }
		}
		desc.BlendState = b
	}
	if p.has_depth {
		d := p.depth_desc
		if d.DepthFunc < 1 || d.DepthFunc > 8 { d.DepthFunc = 8 }
		if d.FrontFace.StencilFailOp < 1 || d.FrontFace.StencilFailOp > 8 { d.FrontFace.StencilFailOp = 1 }
		if d.FrontFace.StencilDepthFailOp < 1 || d.FrontFace.StencilDepthFailOp > 8 { d.FrontFace.StencilDepthFailOp = 1 }
		if d.FrontFace.StencilPassOp < 1 || d.FrontFace.StencilPassOp > 8 { d.FrontFace.StencilPassOp = 1 }
		if d.FrontFace.StencilFunc < 1 || d.FrontFace.StencilFunc > 8 { d.FrontFace.StencilFunc = 8 }
		if d.BackFace.StencilFailOp < 1 || d.BackFace.StencilFailOp > 8 { d.BackFace.StencilFailOp = 1 }
		if d.BackFace.StencilDepthFailOp < 1 || d.BackFace.StencilDepthFailOp > 8 { d.BackFace.StencilDepthFailOp = 1 }
		if d.BackFace.StencilPassOp < 1 || d.BackFace.StencilPassOp > 8 { d.BackFace.StencilPassOp = 1 }
		if d.BackFace.StencilFunc < 1 || d.BackFace.StencilFunc > 8 { d.BackFace.StencilFunc = 8 }
		desc.DepthStencilState = d
	}
	if p.has_rast {
		r := p.rast_desc
		if r.FillMode != 2 && r.FillMode != 3 { r.FillMode = 3 }
		r.CullMode = 1 // D3D12_CULL_MODE_NONE (Xbox RECTLIST / CCW screen quads must not be back-face culled)
		if r.ConservativeRaster > 1 { r.ConservativeRaster = 0 }
		desc.RasterizerState = r
	}

	if p.num_rts > 0 {
		n := min(p.num_rts, u32(8))
		desc.NumRenderTargets = n
		for i in 0 ..< n {
			if p.rt_formats[i] != 0 {
				desc.RTVFormats[i] = map_host_texture_format(p.rt_formats[i])
			}
		}
	} else if p.dsv_format == 0 {
		desc.NumRenderTargets = 1
		desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM
	}

	if p.dsv_format != 0 {
		desc.DSVFormat = map_host_texture_format(p.dsv_format)
	}

	if len(p.input_elems) > 0 {
		desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{
			pInputElementDescs = &p.input_elems[0],
			NumElements        = u32(len(p.input_elems)),
		}
	}
	if len(p.vs_shader.dxil) > 0 {
		desc.VS = D3D12_SHADER_BYTECODE{
			pShaderBytecode = &p.vs_shader.dxil[0],
			BytecodeLength  = uint(len(p.vs_shader.dxil)),
		}
	}
	if len(p.ps_shader.dxil) > 0 {
		desc.PS = D3D12_SHADER_BYTECODE{
			pShaderBytecode = &p.ps_shader.dxil[0],
			BytecodeLength  = uint(len(p.ps_shader.dxil)),
		}
	}
	return desc
}

// Lazily translates captured Xbox shader bytecode and builds a real PC
// ID3D12RootSignature + ID3D12PipelineState on first draw/dispatch.
ensure_host_pipeline :: proc(p: ^Console_Pipeline) -> (root: rawptr, pso: rawptr, ok: bool) {
	if p == nil {
		return nil, nil, false
	}

	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)

	if p.host_attempted {
		return p.host_root, p.host_pso, p.host_root != nil && p.host_pso != nil
	}
	p.host_attempted = true

	if p.is_compute {
		if len(p.cs_bytes) == 0 {
			return nil, nil, false
		}
		cs_hs, _, cs_err := host_shader_from_container(p.cs_bytes, false)
		if cs_err != .None || len(cs_hs.dxil) == 0 {
			vasperty_shader.destroy_host_shader(&cs_hs)
			return nil, nil, false
		}
		if ok_s, msg_s, _ := vasperty_shader.sign_dxil_in_place(cs_hs.dxil[:]); !ok_s {
			delete(msg_s)
			vasperty_shader.destroy_host_shader(&cs_hs)
			return nil, nil, false
		}
		p.cs_shader = cs_hs
	} else {
		if len(p.vs_bytes) == 0 {
			return nil, nil, false
		}
		vs_hs, _, vs_err := host_shader_from_container(p.vs_bytes, false)
		if vs_err != .None || len(vs_hs.dxil) == 0 {
			vasperty_shader.destroy_host_shader(&vs_hs)
			return nil, nil, false
		}
		if ok_s, msg_s, _ := vasperty_shader.sign_dxil_in_place(vs_hs.dxil[:]); !ok_s {
			delete(msg_s)
			vasperty_shader.destroy_host_shader(&vs_hs)
			return nil, nil, false
		}
		if len(p.ps_bytes) > 0 {
			ps_hs, _, ps_err := host_shader_from_container(p.ps_bytes, false)
			if ps_err != .None || len(ps_hs.dxil) == 0 {
				vasperty_shader.destroy_host_shader(&vs_hs)
				vasperty_shader.destroy_host_shader(&ps_hs)
				return nil, nil, false
			}
			if ok_s, msg_s, _ := vasperty_shader.sign_dxil_in_place(ps_hs.dxil[:]); !ok_s {
				delete(msg_s)
				vasperty_shader.destroy_host_shader(&vs_hs)
				vasperty_shader.destroy_host_shader(&ps_hs)
				return nil, nil, false
			}
			p.ps_shader = ps_hs
		}
		p.vs_shader = vs_hs
	}

	hdev := ensure_host_device()
	if hdev == nil {
		return nil, nil, false
	}

	root_sig := build_host_root_signature(hdev, p)
	if root_sig == nil {
		return nil, nil, false
	}

	dvt := (cast(^^Pso_Dev_Vtbl)hdev)^
	pso_iid := IID_ID3D12PipelineState_G
	pso_obj: rawptr
	hr := E_NOTIMPL

	if p.is_compute {
		pso_desc := D3D12_COMPUTE_PIPELINE_STATE_DESC{
			pRootSignature = root_sig,
			CS = D3D12_SHADER_BYTECODE{
				pShaderBytecode = &p.cs_shader.dxil[0],
				BytecodeLength  = uint(len(p.cs_shader.dxil)),
			},
		}
		hr = dvt.CreateComputePipelineState(hdev, &pso_desc, &pso_iid, &pso_obj)
	} else {
		pso_desc := default_graphics_pso_desc(p, root_sig)
		hr = dvt.CreateGraphicsPipelineState(hdev, &pso_desc, &pso_iid, &pso_obj)
	}

	if hr < 0 || pso_obj == nil {
		intrinsics.atomic_add(&g_stat_pso_fail, 1)
		com_release(root_sig)
		return nil, nil, false
	}

	intrinsics.atomic_add(&g_stat_pso_ok, 1)
	p.host_root = root_sig
	p.host_pso = pso_obj
	return p.host_root, p.host_pso, true
}
