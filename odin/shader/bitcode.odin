package vasperty_shader

import "core:strings"

// LLVM 3.7 / DXIL VBR/unabbreviated bitstream writer and IR module builder.

Ty :: distinct u32
V_Kind :: enum { Global, Func, Const, Inst }
V :: struct {
	kind: V_Kind,
	id:   u32,
}

Bin_Op :: enum u32 {
	Add  = 0,
	Sub  = 1,
	Mul  = 2,
	UDiv = 3,
	SDiv = 4,
	URem = 5,
	Shl  = 7,
	LShr = 8,
	AShr = 9,
	And  = 10,
	Or   = 11,
	Xor  = 12,
}

Rmw_Op :: enum u32 {
	Xchg = 0, Add = 1, Sub = 2, And = 3, Or = 5, Xor = 6, Max = 7, Min = 8, UMax = 9, UMin = 10,
}

Cast_Op :: enum u32 {
	Trunc = 0, ZExt = 1, SExt = 2, FpToUi = 3, FpToSi = 4, UiToFp = 5, SiToFp = 6, Bitcast = 11,
}

PRED_FALSE :: u8(0)
PRED_OEQ :: u8(1)
PRED_OGT :: u8(2)
PRED_OGE :: u8(3)
PRED_OLT :: u8(4)
PRED_OLE :: u8(5)
PRED_ORD :: u8(7)
PRED_UNO :: u8(8)
PRED_UEQ :: u8(9)
PRED_UGT :: u8(10)
PRED_UGE :: u8(11)
PRED_ULT :: u8(12)
PRED_ULE :: u8(13)
PRED_UNE :: u8(14)
PRED_TRUE :: u8(15)
PRED_EQ :: u8(32)
PRED_NE :: u8(33)
PRED_IUGT :: u8(34)
PRED_IUGE :: u8(35)
PRED_IULT :: u8(36)
PRED_IULE :: u8(37)
PRED_SGT :: u8(38)
PRED_SGE :: u8(39)
PRED_SLT :: u8(40)
PRED_SLE :: u8(41)

Attr_Kind :: enum u64 {
	None         = 0,
	Read_None    = 1,
	No_Unwind    = 2,
	Read_Only    = 3,
	No_Duplicate = 4,
}

Md :: distinct u32

@(private)
Type_Kind :: enum { Void, Int, Float, Ptr, Struct, Array, Func }

@(private)
Type_Def :: struct {
	kind:     Type_Kind,
	bits:     u32,
	space:    u32,
	elem:     Ty,
	count:    u32,
	has_name: bool,
	name:     string,
	fields:   []Ty,
}

@(private)
Const_Kind :: enum { Undef, Int, Float, Aggregate }
@(private)
Const_Def :: struct {
	kind:  Const_Kind,
	ty:    Ty,
	ival:  i64,
	fval:  u32,
	elems: []u32,
}

@(private)
Global_Def :: struct {
	name:     string,
	ty:       Ty,
	ptr:      Ty,
	space:    u32,
	has_init: bool,
	init:     u32,
}

@(private)
Func_Def :: struct {
	name: string,
	ty:   Ty,
	attr: Attr_Kind,
	body: bool,
}

@(private)
Op_Kind :: enum { Bin, Cast, Cmp, Select, Extract, Call, Phi, Gep, Load, Store, Atomic_Rmw, Cmp_Xchg }
@(private)
Inst_Def :: struct {
	ty:       Ty,
	kind:     Op_Kind,
	bin:      Bin_Op,
	cast_op:  Cast_Op,
	cmp_pred: u8,
	rmw:      Rmw_Op,
	a, b, c:  V,
	idx:      u32,
	fn_id:    u32,
	gep_ty:   Ty,
	args:     []V,
	phi_in:   []struct{ val: V, blk: int },
}

Term_Kind :: enum { Unset, Br, Cond_Br, Ret }
Term :: struct {
	kind:  Term_Kind,
	cond:  V,
	t_blk: int,
	f_blk: int,
}

@(private)
Bc_Block :: struct {
	phis: [dynamic]u32,
	body: [dynamic]u32,
	term: Term,
}

@(private)
Md_Kind :: enum { Str, Value, Node }
@(private)
Md_Op :: struct { present: bool, id: Md }
@(private)
Md_Def :: struct {
	kind: Md_Kind,
	str:  string,
	ty:   Ty,
	val:  V,
	ops:  []Md_Op,
}

Bc_Module :: struct {
	types:   [dynamic]Type_Def,
	consts:  [dynamic]Const_Def,
	globals: [dynamic]Global_Def,
	funcs:   [dynamic]Func_Def,
	insts:   [dynamic]Inst_Def,
	blocks:  [dynamic]Bc_Block,
	mds:     [dynamic]Md_Def,
	named:   [dynamic]struct{ name: string, nodes: []Md },
}

destroy_bc_module :: proc(m: ^Bc_Module) {
	for t in m.types {
		if t.has_name { delete(t.name) }
		delete(t.fields)
	}
	delete(m.types)
	for c in m.consts { delete(c.elems) }
	delete(m.consts)
	for g in m.globals { delete(g.name) }
	delete(m.globals)
	for f in m.funcs { delete(f.name) }
	delete(m.funcs)
	for i in m.insts {
		delete(i.args)
		delete(i.phi_in)
	}
	delete(m.insts)
	for b in m.blocks {
		delete(b.phis)
		delete(b.body)
	}
	delete(m.blocks)
	for md in m.mds {
		if md.kind == .Str { delete(md.str) }
		delete(md.ops)
	}
	delete(m.mds)
	for n in m.named {
		delete(n.name)
		delete(n.nodes)
	}
	delete(m.named)
	m^ = {}
}

@(private)
bc_find_or_add_ty :: proc(m: ^Bc_Module, def: Type_Def) -> Ty {
	for t, i in m.types {
		if t.kind == def.kind && t.bits == def.bits && t.space == def.space && t.elem == def.elem &&
			t.count == def.count && t.has_name == def.has_name && t.name == def.name && len(t.fields) == len(def.fields) {
			eq := true
			for f, fi in t.fields {
				if f != def.fields[fi] { eq = false; break }
			}
			if eq {
				if def.has_name { delete(def.name) }
				delete(def.fields)
				return Ty(i)
			}
		}
	}
	id := Ty(len(m.types))
	append(&m.types, def)
	return id
}

bc_void :: proc(m: ^Bc_Module) -> Ty { return bc_find_or_add_ty(m, Type_Def{kind = .Void}) }
bc_float :: proc(m: ^Bc_Module) -> Ty { return bc_find_or_add_ty(m, Type_Def{kind = .Float}) }
bc_int_ty :: proc(m: ^Bc_Module, bits: u32) -> Ty { return bc_find_or_add_ty(m, Type_Def{kind = .Int, bits = bits}) }
bc_ptr :: proc(m: ^Bc_Module, elem: Ty, space: u32 = 0) -> Ty { return bc_find_or_add_ty(m, Type_Def{kind = .Ptr, elem = elem, space = space}) }
bc_array :: proc(m: ^Bc_Module, n: u32, elem: Ty) -> Ty { return bc_find_or_add_ty(m, Type_Def{kind = .Array, count = n, elem = elem}) }
bc_named_struct :: proc(m: ^Bc_Module, name: string, fields: []Ty) -> Ty {
	f_cp := make([]Ty, len(fields)); copy(f_cp, fields)
	return bc_find_or_add_ty(m, Type_Def{kind = .Struct, has_name = true, name = strings.clone(name), fields = f_cp})
}
bc_anon_struct :: proc(m: ^Bc_Module, fields: []Ty) -> Ty {
	f_cp := make([]Ty, len(fields)); copy(f_cp, fields)
	return bc_find_or_add_ty(m, Type_Def{kind = .Struct, fields = f_cp})
}
bc_func_ty :: proc(m: ^Bc_Module, ret: Ty, params: []Ty) -> Ty {
	p_cp := make([]Ty, len(params)); copy(p_cp, params)
	return bc_find_or_add_ty(m, Type_Def{kind = .Func, elem = ret, fields = p_cp})
}

bc_function :: proc(m: ^Bc_Module, name: string, fty: Ty, attr: Attr_Kind, has_body: bool) -> V {
	for f, i in m.funcs {
		if f.name == name && f.ty == fty {
			return V{kind = .Func, id = u32(i)}
		}
	}
	id := u32(len(m.funcs))
	append(&m.funcs, Func_Def{name = strings.clone(name), ty = fty, attr = attr, body = has_body})
	return V{kind = .Func, id = id}
}

bc_global :: proc(m: ^Bc_Module, name: string, ty: Ty, space: u32, has_init := false, init_c: V = {}) -> V {
	ptr := bc_ptr(m, ty, space)
	id := u32(len(m.globals))
	append(&m.globals, Global_Def{name = strings.clone(name), ty = ty, ptr = ptr, space = space, has_init = has_init, init = init_c.id})
	return V{kind = .Global, id = id}
}

@(private)
bc_const :: proc(m: ^Bc_Module, def: Const_Def) -> V {
	for c, i in m.consts {
		if c.kind == def.kind && c.ty == def.ty && c.ival == def.ival && c.fval == def.fval && len(c.elems) == len(def.elems) {
			eq := true
			for e, ei in c.elems {
				if e != def.elems[ei] { eq = false; break }
			}
			if eq {
				delete(def.elems)
				return V{kind = .Const, id = u32(i)}
			}
		}
	}
	id := u32(len(m.consts))
	append(&m.consts, def)
	return V{kind = .Const, id = id}
}

bc_undef :: proc(m: ^Bc_Module, ty: Ty) -> V { return bc_const(m, Const_Def{kind = .Undef, ty = ty}) }
bc_i1 :: proc(m: ^Bc_Module, v: bool) -> V { return bc_const(m, Const_Def{kind = .Int, ty = bc_int_ty(m, 1), ival = 1 if v else 0}) }
bc_i8 :: proc(m: ^Bc_Module, v: u8) -> V { return bc_const(m, Const_Def{kind = .Int, ty = bc_int_ty(m, 8), ival = i64(i8(v))}) }
bc_i32 :: proc(m: ^Bc_Module, v: u32) -> V { return bc_const(m, Const_Def{kind = .Int, ty = bc_int_ty(m, 32), ival = i64(i32(v))}) }
bc_i64 :: proc(m: ^Bc_Module, v: i64) -> V { return bc_const(m, Const_Def{kind = .Int, ty = bc_int_ty(m, 64), ival = v}) }
bc_f32_bits :: proc(m: ^Bc_Module, bits: u32) -> V { return bc_const(m, Const_Def{kind = .Float, ty = bc_float(m), fval = bits}) }
bc_aggregate :: proc(m: ^Bc_Module, ty: Ty, elems: []V) -> V {
	ids := make([]u32, len(elems))
	for e, i in elems { ids[i] = e.id }
	return bc_const(m, Const_Def{kind = .Aggregate, ty = ty, elems = ids})
}

bc_replace_const :: proc(m: ^Bc_Module, old_v, new_v: V) {
	if int(old_v.id) < len(m.consts) && int(new_v.id) < len(m.consts) {
		old_elems := m.consts[old_v.id].elems
		src := m.consts[new_v.id]
		cp: []u32 = nil
		if len(src.elems) > 0 {
			cp = make([]u32, len(src.elems))
			copy(cp, src.elems)
		}
		m.consts[old_v.id] = Const_Def{kind = src.kind, ty = src.ty, ival = src.ival, fval = src.fval, elems = cp}
		delete(old_elems)
	}
}

bc_new_block :: proc(m: ^Bc_Module) -> int {
	id := len(m.blocks)
	append(&m.blocks, Bc_Block{})
	return id
}

bc_type_of :: proc(m: ^Bc_Module, v: V) -> Ty {
	switch v.kind {
	case .Global: return m.globals[v.id].ptr
	case .Func:   return bc_ptr(m, m.funcs[v.id].ty)
	case .Const:  return m.consts[v.id].ty
	case .Inst:   return m.insts[v.id].ty
	}
	return 0
}

@(private)
bc_push :: proc(m: ^Bc_Module, blk: int, inst: Inst_Def) -> V {
	id := u32(len(m.insts))
	append(&m.insts, inst)
	append(&m.blocks[blk].body, id)
	return V{kind = .Inst, id = id}
}

bc_bin :: proc(m: ^Bc_Module, blk: int, op: Bin_Op, a, b: V) -> V {
	return bc_push(m, blk, Inst_Def{ty = bc_type_of(m, a), kind = .Bin, bin = op, a = a, b = b})
}
bc_cast :: proc(m: ^Bc_Module, blk: int, op: Cast_Op, a: V, ty: Ty) -> V {
	return bc_push(m, blk, Inst_Def{ty = ty, kind = .Cast, cast_op = op, a = a})
}
bc_cmp :: proc(m: ^Bc_Module, blk: int, pred: u8, a, b: V) -> V {
	return bc_push(m, blk, Inst_Def{ty = bc_int_ty(m, 1), kind = .Cmp, cmp_pred = pred, a = a, b = b})
}
bc_select :: proc(m: ^Bc_Module, blk: int, c, t, f: V) -> V {
	return bc_push(m, blk, Inst_Def{ty = bc_type_of(m, t), kind = .Select, a = c, b = t, c = f})
}
bc_extract :: proc(m: ^Bc_Module, blk: int, agg: V, index: u32) -> V {
	td := m.types[bc_type_of(m, agg)]
	rty := td.fields[index] if td.kind == .Struct else td.elem
	return bc_push(m, blk, Inst_Def{ty = rty, kind = .Extract, a = agg, idx = index})
}
bc_call :: proc(m: ^Bc_Module, blk: int, f: V, args: []V) -> V {
	fty := m.types[m.funcs[f.id].ty]
	cp := make([]V, len(args)); copy(cp, args)
	return bc_push(m, blk, Inst_Def{ty = fty.elem, kind = .Call, fn_id = f.id, args = cp})
}
bc_phi :: proc(m: ^Bc_Module, blk: int, ty: Ty) -> V {
	id := u32(len(m.insts))
	append(&m.insts, Inst_Def{ty = ty, kind = .Phi})
	append(&m.blocks[blk].phis, id)
	return V{kind = .Inst, id = id}
}
bc_set_phi :: proc(m: ^Bc_Module, phi: V, incoming: []struct{ val: V, blk: int }) {
	cp := make([]struct{ val: V, blk: int }, len(incoming))
	copy(cp, incoming)
	delete(m.insts[phi.id].phi_in)
	m.insts[phi.id].phi_in = cp
}
bc_gep_elem :: proc(m: ^Bc_Module, blk: int, ptr, index: V) -> V {
	pt := m.types[bc_type_of(m, ptr)]
	arr_ty := pt.elem
	elem_ty := m.types[arr_ty].elem
	rty := bc_ptr(m, elem_ty, pt.space)
	idxs := make([]V, 2)
	idxs[0] = bc_i32(m, 0)
	idxs[1] = index
	return bc_push(m, blk, Inst_Def{ty = rty, kind = .Gep, gep_ty = arr_ty, a = ptr, args = idxs})
}
bc_load :: proc(m: ^Bc_Module, blk: int, ptr: V) -> V {
	pt := m.types[bc_type_of(m, ptr)]
	return bc_push(m, blk, Inst_Def{ty = pt.elem, kind = .Load, a = ptr})
}
bc_store :: proc(m: ^Bc_Module, blk: int, ptr, val: V) {
	_ = bc_push(m, blk, Inst_Def{ty = bc_void(m), kind = .Store, a = ptr, b = val})
}
bc_atomic :: proc(m: ^Bc_Module, blk: int, op: Rmw_Op, ptr, val: V) -> V {
	return bc_push(m, blk, Inst_Def{ty = bc_type_of(m, val), kind = .Atomic_Rmw, rmw = op, a = ptr, b = val})
}
bc_terminate :: proc(m: ^Bc_Module, blk: int, t: Term) {
	m.blocks[blk].term = t
}

bc_md_str :: proc(m: ^Bc_Module, s: string) -> Md {
	id := Md(len(m.mds))
	append(&m.mds, Md_Def{kind = .Str, str = strings.clone(s)})
	return id
}
bc_md_val :: proc(m: ^Bc_Module, v: V) -> Md {
	ty := bc_type_of(m, v)
	id := Md(len(m.mds))
	append(&m.mds, Md_Def{kind = .Value, ty = ty, val = v})
	return id
}
bc_md_node :: proc(m: ^Bc_Module, ops: []Md_Op) -> Md {
	cp := make([]Md_Op, len(ops)); copy(cp, ops)
	id := Md(len(m.mds))
	append(&m.mds, Md_Def{kind = .Node, ops = cp})
	return id
}
bc_named_md :: proc(m: ^Bc_Module, name: string, nodes: []Md) {
	cp := make([]Md, len(nodes)); copy(cp, nodes)
	append(&m.named, struct{ name: string, nodes: []Md }{name = strings.clone(name), nodes = cp})
}

// Bitstream encoder

@(private)
Bit_Writer :: struct {
	words: [dynamic]u32,
	cur:   u64,
	bits:  u32,
	stack: [dynamic]struct{ width: u32, start: int },
}

@(private)
bw_emit :: proc(w: ^Bit_Writer, v: u64, width: u32) {
	w.cur |= v << w.bits
	w.bits += width
	for w.bits >= 32 {
		append(&w.words, u32(w.cur))
		w.cur >>= 32
		w.bits -= 32
	}
}
@(private)
bw_vbr :: proc(w: ^Bit_Writer, val: u64, width: u32) {
	v := val
	hi := u64(1) << (width - 1)
	for v >= hi {
		bw_emit(w, (v & (hi - 1)) | hi, width)
		v >>= (width - 1)
	}
	bw_emit(w, v, width)
}
@(private)
bw_align :: proc(w: ^Bit_Writer) {
	if w.bits > 0 {
		append(&w.words, u32(w.cur))
		w.cur = 0
		w.bits = 0
	}
}
@(private)
bw_width :: proc(w: ^Bit_Writer) -> u32 {
	return w.stack[len(w.stack) - 1].width if len(w.stack) > 0 else 2
}
@(private)
bw_enter :: proc(w: ^Bit_Writer, id: u64, width: u32) {
	bw_emit(w, 1, bw_width(w))
	bw_vbr(w, id, 8)
	bw_vbr(w, u64(width), 4)
	bw_align(w)
	append(&w.words, 0)
	append(&w.stack, struct{ width: u32, start: int }{width = width, start = len(w.words)})
}
@(private)
bw_exit :: proc(w: ^Bit_Writer) {
	bw_emit(w, 0, bw_width(w))
	bw_align(w)
	top := w.stack[len(w.stack) - 1]
	pop(&w.stack)
	w.words[top.start - 1] = u32(len(w.words) - top.start)
}
@(private)
bw_record :: proc(w: ^Bit_Writer, code: u64, ops: []u64) {
	bw_emit(w, 3, bw_width(w))
	bw_vbr(w, code, 6)
	bw_vbr(w, u64(len(ops)), 6)
	for o in ops { bw_vbr(w, o, 6) }
}
@(private)
bw_signed :: proc(v: i64) -> u64 {
	return (u64(v) << 1) if v >= 0 else ((u64(-v) << 1) | 1)
}
@(private)
bw_chars :: proc(s: string) -> []u64 {
	r := make([]u64, len(s), context.temp_allocator)
	for b, i in transmute([]u8)s { r[i] = u64(b) }
	return r
}

bc_write :: proc(m: ^Bc_Module, allocator := context.allocator) -> []u8 {
	// Reverse postorder reachable blocks
	seen := make([]bool, len(m.blocks), context.temp_allocator)
	post := make([dynamic]int, 0, len(m.blocks), context.temp_allocator)
	dfs :: proc(m: ^Bc_Module, b: int, seen: []bool, post: ^[dynamic]int) {
		seen[b] = true
		t := m.blocks[b].term
		if t.kind == .Br {
			if !seen[t.t_blk] { dfs(m, t.t_blk, seen, post) }
		} else if t.kind == .Cond_Br {
			if !seen[t.t_blk] { dfs(m, t.t_blk, seen, post) }
			if !seen[t.f_blk] { dfs(m, t.f_blk, seen, post) }
		}
		append(post, b)
	}
	if len(m.blocks) > 0 { dfs(m, 0, seen, &post) }
	layout := make([]int, len(post), context.temp_allocator)
	bpos := make([]u64, len(m.blocks), context.temp_allocator)
	for i in 0 ..< len(m.blocks) { bpos[i] = 0xFFFFFFFFFFFFFFFF }
	for i in 0 ..< len(post) {
		b := post[len(post) - 1 - i]
		layout[i] = b
		bpos[b] = u64(i)
	}

	g_n := u32(len(m.globals))
	f_n := u32(len(m.funcs))
	funcs_base := g_n
	consts_base := funcs_base + f_n
	insts_base := consts_base + u32(len(m.consts))

	void_ty := bc_void(m)
	inst_ids := make([]u32, len(m.insts), context.temp_allocator)
	for i in 0 ..< len(inst_ids) { inst_ids[i] = 0xFFFFFFFF }
	next_id := insts_base
	for b in layout {
		for pi in m.blocks[b].phis {
			if m.insts[pi].ty != void_ty { inst_ids[pi] = next_id; next_id += 1 }
		}
		for bi in m.blocks[b].body {
			if m.insts[bi].ty != void_ty { inst_ids[bi] = next_id; next_id += 1 }
		}
	}
	abs_id :: proc(v: V, funcs_base, consts_base: u32, inst_ids: []u32) -> u32 {
		switch v.kind {
		case .Global: return v.id
		case .Func:   return funcs_base + v.id
		case .Const:  return consts_base + v.id
		case .Inst:   return inst_ids[v.id]
		}
		return 0
	}

	w := Bit_Writer{
		words = make([dynamic]u32, 0, 1024, context.temp_allocator),
		stack = make([dynamic]struct{ width: u32, start: int }, 0, 8, context.temp_allocator),
	}
	bw_emit(&w, 'B', 8); bw_emit(&w, 'C', 8); bw_emit(&w, 0xC0, 8); bw_emit(&w, 0xDE, 8)
	bw_enter(&w, 8, 3)
	bw_record(&w, 1, []u64{1})

	// PARAMATTR_GROUP_BLOCK & PARAMATTR_BLOCK
	bw_enter(&w, 10, 3)
	bw_record(&w, 3, []u64{1, 0xFFFFFFFF, 0, 18, 0, 20})
	bw_record(&w, 3, []u64{2, 0xFFFFFFFF, 0, 18})
	bw_record(&w, 3, []u64{3, 0xFFFFFFFF, 0, 18, 0, 21})
	bw_record(&w, 3, []u64{4, 0xFFFFFFFF, 0, 12, 0, 18})
	bw_exit(&w)
	bw_enter(&w, 9, 3)
	for id in 1 ..= 4 { bw_record(&w, 2, []u64{u64(id)}) }
	bw_exit(&w)

	// TYPE_BLOCK
	bw_enter(&w, 17, 4)
	bw_record(&w, 1, []u64{u64(len(m.types))})
	ops := make([dynamic]u64, 0, 16, context.temp_allocator)
	for t in m.types {
		clear(&ops)
		switch t.kind {
		case .Void:  bw_record(&w, 2, nil)
		case .Float: bw_record(&w, 3, nil)
		case .Int:   bw_record(&w, 7, []u64{u64(t.bits)})
		case .Ptr:   bw_record(&w, 8, []u64{u64(t.elem), u64(t.space)})
		case .Array: bw_record(&w, 11, []u64{u64(t.count), u64(t.elem)})
		case .Struct:
			append(&ops, 0)
			for fld in t.fields { append(&ops, u64(fld)) }
			if t.has_name {
				bw_record(&w, 19, bw_chars(t.name))
				bw_record(&w, 20, ops[:])
			} else {
				bw_record(&w, 18, ops[:])
			}
		case .Func:
			append(&ops, 0, u64(t.elem))
			for fld in t.fields { append(&ops, u64(fld)) }
			bw_record(&w, 21, ops[:])
		}
	}
	bw_exit(&w)

	bw_record(&w, 2, bw_chars("dxil-ms-dx"))
	bw_record(&w, 3, bw_chars("e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64"))

	for g in m.globals {
		is_c := u64(1) if g.has_init else u64(0)
		init_id := u64(consts_base + g.init + 1) if g.has_init else u64(0)
		link := u64(3) if g.has_init else u64(0)
		bw_record(&w, 7, []u64{u64(g.ty), (u64(g.space) << 2) | 2 | is_c, init_id, link, 3, 0})
	}
	for f in m.funcs {
		proto := u64(0) if f.body else u64(1)
		bw_record(&w, 8, []u64{u64(f.ty), 0, proto, 0, u64(f.attr), 0, 0, 0, 0, 0, 0, 0, 0, 0})
	}

	// CONSTANTS_BLOCK
	bw_enter(&w, 11, 4)
	has_cur_ty := false
	cur_ty: Ty = 0
	for c in m.consts {
		if !has_cur_ty || cur_ty != c.ty {
			bw_record(&w, 1, []u64{u64(c.ty)})
			cur_ty = c.ty; has_cur_ty = true
		}
		switch c.kind {
		case .Undef: bw_record(&w, 3, nil)
		case .Int:   bw_record(&w, 4, []u64{bw_signed(c.ival)})
		case .Float: bw_record(&w, 6, []u64{u64(c.fval)})
		case .Aggregate:
			clear(&ops)
			for ei in c.elems { append(&ops, u64(consts_base + ei)) }
			bw_record(&w, 7, ops[:])
		}
	}
	bw_exit(&w)

	// METADATA_BLOCK
	bw_enter(&w, 15, 3)
	for md in m.mds {
		switch md.kind {
		case .Str:   bw_record(&w, 1, bw_chars(md.str))
		case .Value: bw_record(&w, 2, []u64{u64(md.ty), u64(abs_id(md.val, funcs_base, consts_base, inst_ids))})
		case .Node:
			clear(&ops)
			for o in md.ops { append(&ops, (u64(o.id) + 1) if o.present else u64(0)) }
			bw_record(&w, 3, ops[:])
		}
	}
	for nm in m.named {
		bw_record(&w, 4, bw_chars(nm.name))
		clear(&ops)
		for nid in nm.nodes { append(&ops, u64(nid)) }
		bw_record(&w, 10, ops[:])
	}
	bw_exit(&w)

	// Standard LLVM 3.7 metadata kinds block
	bw_enter(&w, 15, 3)
	kinds := [?]string{"dbg", "tbaa", "prof", "fpmath", "range", "tbaa.struct", "invariant.load", "alias.scope", "noalias", "nontemporal", "llvm.mem.parallel_loop_access", "nonnull", "dereferenceable", "dereferenceable_or_null", "make.implicit", "unpredictable", "invariant.group", "align"}
	for kd, ki in kinds {
		clear(&ops)
		append(&ops, u64(ki))
		for ch in bw_chars(kd) { append(&ops, ch) }
		bw_record(&w, 11, ops[:])
	}
	bw_exit(&w)

	// VALUE_SYMTAB_BLOCK
	bw_enter(&w, 14, 4)
	for g, gi in m.globals {
		clear(&ops); append(&ops, u64(gi)); for ch in bw_chars(g.name) { append(&ops, ch) }
		bw_record(&w, 1, ops[:])
	}
	for f, fi in m.funcs {
		clear(&ops); append(&ops, u64(funcs_base) + u64(fi)); for ch in bw_chars(f.name) { append(&ops, ch) }
		bw_record(&w, 1, ops[:])
	}
	bw_exit(&w)

	// FUNCTION_BLOCK for `main`
	bw_enter(&w, 12, 4)
	bw_record(&w, 1, []u64{u64(len(layout))})
	inst_id := insts_base
	for b in layout {
		rel :: proc(v: V, iid, fb, cb: u32, inst_ids: []u32) -> u64 {
			return u64(iid - abs_id(v, fb, cb, inst_ids))
		}
		for iid in m.blocks[b].phis {
			inst := m.insts[iid]
			clear(&ops); append(&ops, u64(inst.ty))
			for pi in inst.phi_in {
				append(&ops, bw_signed(i64(inst_id) - i64(abs_id(pi.val, funcs_base, consts_base, inst_ids))), bpos[pi.blk])
			}
			bw_record(&w, 16, ops[:])
			if inst.ty != void_ty { inst_id += 1 }
		}
		for iid in m.blocks[b].body {
			inst := m.insts[iid]
			switch inst.kind {
			case .Bin:
				bw_record(&w, 2, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), rel(inst.b, inst_id, funcs_base, consts_base, inst_ids), u64(inst.bin)})
			case .Cast:
				bw_record(&w, 3, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), u64(inst.ty), u64(inst.cast_op)})
			case .Cmp:
				bw_record(&w, 28, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), rel(inst.b, inst_id, funcs_base, consts_base, inst_ids), u64(inst.cmp_pred)})
			case .Select:
				bw_record(&w, 29, []u64{rel(inst.b, inst_id, funcs_base, consts_base, inst_ids), rel(inst.c, inst_id, funcs_base, consts_base, inst_ids), rel(inst.a, inst_id, funcs_base, consts_base, inst_ids)})
			case .Extract:
				bw_record(&w, 26, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), u64(inst.idx)})
			case .Call:
				clear(&ops)
				append(&ops, 0, u64(1) << 15, u64(m.funcs[inst.fn_id].ty), rel(V{kind = .Func, id = inst.fn_id}, inst_id, funcs_base, consts_base, inst_ids))
				for a in inst.args { append(&ops, rel(a, inst_id, funcs_base, consts_base, inst_ids)) }
				bw_record(&w, 34, ops[:])
			case .Phi:
			case .Gep:
				clear(&ops)
				append(&ops, 0, u64(inst.gep_ty), rel(inst.a, inst_id, funcs_base, consts_base, inst_ids))
				for a in inst.args { append(&ops, rel(a, inst_id, funcs_base, consts_base, inst_ids)) }
				bw_record(&w, 43, ops[:])
			case .Load:
				bw_record(&w, 20, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), u64(inst.ty), 3, 0})
			case .Store:
				bw_record(&w, 44, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), rel(inst.b, inst_id, funcs_base, consts_base, inst_ids), 3, 0})
			case .Atomic_Rmw:
				bw_record(&w, 38, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), rel(inst.b, inst_id, funcs_base, consts_base, inst_ids), u64(inst.rmw), 0, 6, 1})
			case .Cmp_Xchg:
				bw_record(&w, 46, []u64{rel(inst.a, inst_id, funcs_base, consts_base, inst_ids), rel(inst.b, inst_id, funcs_base, consts_base, inst_ids), rel(inst.c, inst_id, funcs_base, consts_base, inst_ids), 0, 6, 1, 6, 0})
			}
			if inst.ty != void_ty { inst_id += 1 }
		}
		term := m.blocks[b].term
		switch term.kind {
		case .Unset, .Ret: bw_record(&w, 10, nil)
		case .Br:          bw_record(&w, 11, []u64{bpos[term.t_blk]})
		case .Cond_Br:
			a := abs_id(term.cond, funcs_base, consts_base, inst_ids)
			bw_record(&w, 11, []u64{bpos[term.t_blk], bpos[term.f_blk], u64(inst_id - a)})
		}
	}
	bw_exit(&w)
	bw_exit(&w)
	bw_align(&w)

	out := make([]u8, len(w.words) * 4, allocator)
	for wd, wi in w.words {
		out[4 * wi + 0] = u8(wd)
		out[4 * wi + 1] = u8(wd >> 8)
		out[4 * wi + 2] = u8(wd >> 16)
		out[4 * wi + 3] = u8(wd >> 24)
	}
	return out
}
