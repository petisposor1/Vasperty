package vasperty_shader

import "core:slice"
import "core:strings"

VCC :: VCC_SCALAR
M0 :: M0_SCALAR
EXEC :: EXEC_SCALAR
SSA_NONE :: Value(0xFFFF_FFFF)

Value :: distinct u32

Reg_Kind :: enum u8 {
	S,
	Scc,
	V,
}

Reg :: struct {
	kind: Reg_Kind,
	code: u8,
}

reg_s :: proc(c: u8) -> Reg {
	return Reg{kind = .S, code = c}
}

reg_scc :: proc() -> Reg {
	return Reg{kind = .Scc, code = 0}
}

reg_v :: proc(r: u8) -> Reg {
	return Reg{kind = .V, code = r}
}

Exit_Kind :: enum u8 {
	Jump,
	Branch,
	End,
	Indirect,
}

Exit :: struct {
	kind:      Exit_Kind,
	target:    int,
	taken:     int,
	not_taken: int,
}

exit_successors :: proc(ex: Exit, buf: ^[2]int) -> []int {
	switch ex.kind {
	case .Jump:
		buf[0] = ex.target
		return buf[:1]
	case .Branch:
		buf[0] = ex.taken
		buf[1] = ex.not_taken
		return buf[:2]
	case .End, .Indirect:
		return buf[:0]
	}
	return buf[:0]
}

Reg_Value :: struct {
	reg: Reg,
	val: Value,
}

Phi :: struct {
	reg:  Reg,
	val:  Value,
	args: [dynamic]Value,
}

Inst :: struct {
	machine: Instruction,
	fields:  Fields,
	reads:   [dynamic]Reg_Value,
	writes:  [dynamic]Reg_Value,
}

inst_name :: proc(inst: ^Inst) -> string {
	return inst.machine.name if inst.machine.has_name else ""
}

inst_read :: proc(inst: ^Inst, r: Reg) -> (Value, bool) {
	for rv in inst.reads {
		if rv.reg == r {
			return rv.val, true
		}
	}
	return 0, false
}

inst_write :: proc(inst: ^Inst, r: Reg) -> (Value, bool) {
	for rv in inst.writes {
		if rv.reg == r {
			return rv.val, true
		}
	}
	return 0, false
}

Block :: struct {
	offset: int,
	preds:  [dynamic]int,
	phis:   [dynamic]Phi,
	insts:  [dynamic]Inst,
	exit:   Exit,
}

Program :: struct {
	wave64:     bool,
	vgprs:      u16,
	blocks:     [dynamic]Block,
	inputs:     [dynamic]Reg_Value,
	next_value: u32,
}

fields_clone :: proc(f: ^Fields) -> Fields {
	out := f^
	if len(f.src) > 0 {
		out.src = make([dynamic]Operand, len(f.src))
		copy(out.src[:], f.src[:])
	} else {
		out.src = nil
	}
	if len(f.valu.src) > 0 {
		out.valu.src = make([dynamic]Operand, len(f.valu.src))
		copy(out.valu.src[:], f.valu.src[:])
	} else {
		out.valu.src = nil
	}
	return out
}

destroy_inst :: proc(inst: ^Inst) {
	destroy_fields(&inst.fields)
	delete(inst.reads)
	delete(inst.writes)
}

destroy_block :: proc(b: ^Block) {
	delete(b.preds)
	for &phi in b.phis {
		delete(phi.args)
	}
	delete(b.phis)
	for &inst in b.insts {
		destroy_inst(&inst)
	}
	delete(b.insts)
}

destroy_program :: proc(p: ^Program) {
	for &b in p.blocks {
		destroy_block(&b)
	}
	delete(p.blocks)
	delete(p.inputs)
}

REGS_COUNT :: 128 + 1 + 256
REGSET_WORDS :: (REGS_COUNT + 63) / 64
Reg_Set :: [REGSET_WORDS]u64

reg_index :: proc(r: Reg) -> int {
	switch r.kind {
	case .S:
		return int(r.code)
	case .Scc:
		return 128
	case .V:
		return 129 + int(r.code)
	}
	return 0
}

reg_at :: proc(idx: int) -> Reg {
	if idx < 128 {
		return Reg{kind = .S, code = u8(idx)}
	}
	if idx == 128 {
		return Reg{kind = .Scc, code = 0}
	}
	return Reg{kind = .V, code = u8(idx - 129)}
}

regset_insert :: proc(s: ^Reg_Set, r: Reg) {
	i := reg_index(r)
	s[i / 64] |= u64(1) << u64(i % 64)
}

regset_contains :: proc(s: ^Reg_Set, r: Reg) -> bool {
	i := reg_index(r)
	return ((s[i / 64] >> u64(i % 64)) & 1) != 0
}

lookup_sorted :: proc(outs: []Reg_Value, r: Reg) -> Value {
	lo := 0
	hi := len(outs)
	target := reg_index(r)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		k := reg_index(outs[mid].reg)
		if k == target {
			return outs[mid].val
		}
		if k < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return SSA_NONE
}

reverse_postorder :: proc(blocks: []Block) -> [dynamic]int {
	out := make([dynamic]int, 0, len(blocks))
	if len(blocks) == 0 {
		return out
	}
	seen := make([]bool, len(blocks))
	defer delete(seen)
	Stack_Item :: struct {
		b: int,
		i: int,
	}
	stack := make([dynamic]Stack_Item, 0, len(blocks))
	defer delete(stack)
	seen[0] = true
	append(&stack, Stack_Item{b = 0, i = 0})
	succ_buf: [2]int
	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		succs := exit_successors(blocks[top.b].exit, &succ_buf)
		if top.i < len(succs) {
			s := succs[top.i]
			top.i += 1
			if s >= 0 && s < len(blocks) && !seen[s] {
				seen[s] = true
				append(&stack, Stack_Item{b = s, i = 0})
			}
		} else {
			append(&out, top.b)
			pop(&stack)
		}
	}
	slice.reverse(out[:])
	return out
}

link_blocks :: proc(blocks: []Block) {
	for &b in blocks {
		clear(&b.preds)
	}
	succ_buf: [2]int
	for bi in 0 ..< len(blocks) {
		succs := exit_successors(blocks[bi].exit, &succ_buf)
		for s in succs {
			append(&blocks[s].preds, bi)
		}
	}
}

idoms :: proc(blocks: []Block, order: []int, idx_map: []int) -> [dynamic]int {
	idom := make([dynamic]int, len(blocks))
	for i in 0 ..< len(idom) {
		idom[i] = -1
	}
	if len(order) == 0 {
		return idom
	}
	entry := order[0]
	idom[entry] = entry

	intersect := proc(idom_s: []int, idx_s: []int, a_in, b_in: int) -> int {
		a := a_in
		b := b_in
		for a != b {
			for idx_s[a] > idx_s[b] {
				a = idom_s[a]
			}
			for idx_s[b] > idx_s[a] {
				b = idom_s[b]
			}
		}
		return a
	}

	changed := true
	for changed {
		changed = false
		for k in 1 ..< len(order) {
			b := order[k]
			new_d := -1
			for q in blocks[b].preds {
				if idom[q] == -1 {
					continue
				}
				if new_d == -1 {
					new_d = q
				} else {
					new_d = intersect(idom[:], idx_map, q, new_d)
				}
			}
			if idom[b] != new_d {
				idom[b] = new_d
				changed = true
			}
		}
	}
	return idom
}

irreducible_edge :: proc(blocks: []Block, order: []int, idx_map: []int) -> (from, to: int, found: bool) {
	if len(order) == 0 {
		return 0, 0, false
	}
	entry := order[0]
	idom := idoms(blocks, order, idx_map)
	defer delete(idom)
	succ_buf: [2]int
	for b in order {
		succs := exit_successors(blocks[b].exit, &succ_buf)
		for s in succs {
			if idx_map[s] > idx_map[b] {
				continue
			}
			d := b
			for d != s && d != entry && d != -1 {
				d = idom[d]
			}
			if d != s {
				return b, s, true
			}
		}
	}
	return 0, 0, false
}

clone_block_shell :: proc(src: ^Block) -> Block {
	dst: Block
	dst.offset = src.offset
	dst.exit = src.exit
	dst.preds = make([dynamic]int, 0, len(src.preds))
	dst.phis = make([dynamic]Phi)
	dst.insts = make([dynamic]Inst, 0, len(src.insts))
	for &inst in src.insts {
		ni: Inst
		ni.machine = inst.machine
		ni.fields = fields_clone(&inst.fields)
		ni.reads = make([dynamic]Reg_Value, len(inst.reads))
		copy(ni.reads[:], inst.reads[:])
		ni.writes = make([dynamic]Reg_Value, len(inst.writes))
		copy(ni.writes[:], inst.writes[:])
		append(&dst.insts, ni)
	}
	return dst
}

remap_exit :: proc(ex: Exit, copies: ^map[int]int) -> Exit {
	res := ex
	switch res.kind {
	case .Jump:
		if v, ok := copies[res.target]; ok {
			res.target = v
		}
	case .Branch:
		if v, ok := copies[res.taken]; ok {
			res.taken = v
		}
		if v, ok := copies[res.not_taken]; ok {
			res.not_taken = v
		}
	case .End, .Indirect:
	}
	return res
}

split_irreducible :: proc(blocks: ^[dynamic]Block) -> Shader_Error {
	for _ in 0 ..< 256 {
		order := reverse_postorder(blocks[:])
		idx_map := make([]int, len(blocks))
		for i in 0 ..< len(idx_map) {
			idx_map[i] = max(int)
		}
		for b, i in order {
			idx_map[b] = i
		}
		edge_from, header, bad := irreducible_edge(blocks[:], order[:], idx_map)
		if !bad {
			delete(order)
			delete(idx_map)
			return .None
		}
		region := make([]bool, len(blocks))
		defer delete(region)
		h_rpo := idx_map[header]
		succ_buf: [2]int
		for b in order {
			if idx_map[b] <= h_rpo {
				continue
			}
			succs := exit_successors(blocks[b].exit, &succ_buf)
			for s in succs {
				if s == header || (idx_map[s] <= h_rpo && s != order[0]) {
					region[b] = true
				}
			}
		}
		if len(blocks) > 16384 {
			delete(order)
			delete(idx_map)
			return .Unsupported
		}
		copies := make(map[int]int)
		defer delete(copies)
		copies[header] = len(blocks)
		append(blocks, clone_block_shell(&blocks[header]))
		for b in order {
			if idx_map[b] > h_rpo && region[b] {
				if _, already := copies[b]; !already {
					copies[b] = len(blocks)
					append(blocks, clone_block_shell(&blocks[b]))
				}
			}
		}
		for _, ci in copies {
			blocks[ci].exit = remap_exit(blocks[ci].exit, &copies)
		}
		ex := &blocks[edge_from].exit
		switch ex.kind {
		case .Jump:
			if ex.target == header {
				ex.target = copies[header]
			}
		case .Branch:
			if ex.taken == header {
				ex.taken = copies[header]
			}
			if ex.not_taken == header {
				ex.not_taken = copies[header]
			}
		case .End, .Indirect:
		}
		link_blocks(blocks[:])
		delete(order)
		delete(idx_map)
	}
	return .Unsupported
}

is_scheduling_noop :: proc(name: string) -> bool {
	return strings.has_prefix(name, "s_waitcnt") ||
		strings.has_prefix(name, "s_nop") ||
		strings.has_prefix(name, "s_sethalt") ||
		strings.has_prefix(name, "s_sleep") ||
		strings.has_prefix(name, "s_setprio") ||
		strings.has_prefix(name, "s_icache_inv") ||
		strings.has_prefix(name, "s_inst_prefetch") ||
		strings.has_prefix(name, "s_endpgm") ||
		strings.has_prefix(name, "s_branch") ||
		strings.has_prefix(name, "s_cbranch_g_fork") ||
		strings.has_prefix(name, "s_cbranch_i_fork") ||
		strings.has_prefix(name, "s_ttracedata") ||
		strings.has_prefix(name, "s_clause")
}

push_reg_range :: proc(list: ^[dynamic]Reg, kind: Reg_Kind, start: u8, count: int) {
	for k in 0 ..< count {
		code := int(start) + k
		if kind == .S && code < 128 {
			append(list, reg_s(u8(code)))
		} else if kind == .V && code < 256 {
			append(list, reg_v(u8(code)))
		}
	}
}

add_operand_reads :: proc(reads: ^[dynamic]Reg, op: Operand) {
	switch op.kind {
	case .Scalar:
		if op.code == NULL_SCALAR {
			return
		}
		if op.code == 0xFD { // SCC inline
			append(reads, reg_scc())
			return
		}
		if op.code < 128 {
			push_reg_range(reads, .S, op.code, int(op.dwords))
		}
	case .Vector:
		push_reg_range(reads, .V, op.code, int(op.dwords))
	case .Const, .Literal, .Attr:
	}
}

sop_is_64 :: proc(name: string) -> bool {
	return strings.has_suffix(name, "_b64") || strings.has_suffix(name, "_u64") || strings.has_suffix(name, "_i64")
}

is_movrel_name :: proc(name: string) -> bool {
	return name == "v_movrels_b32" || name == "v_movreld_b32" || name == "v_movrelsd_b32" || name == "v_swaprel_b32"
}

compute_effects :: proc(
	fields: ^Fields,
	name: string,
	lanes: u8,
	vgprs: u16,
	m0_max: Maybe(u8),
) -> (reads: [dynamic]Reg, writes: [dynamic]Reg, skip: bool, err: Shader_Error) {
	if is_scheduling_noop(name) {
		return nil, nil, true, .None
	}
	reads = make([dynamic]Reg, 0, 8)
	writes = make([dynamic]Reg, 0, 8)

	switch fields.kind {
	case .Sopp:
		if strings.has_prefix(name, "s_cbranch_") {
			if name == "s_cbranch_scc0" || name == "s_cbranch_scc1" {
				append(&reads, reg_scc())
			} else if name == "s_cbranch_vccz" || name == "s_cbranch_vccnz" {
				push_reg_range(&reads, .S, VCC, int(lanes))
			} else if name == "s_cbranch_execz" || name == "s_cbranch_execnz" {
				push_reg_range(&reads, .S, EXEC, int(lanes))
			}
			return reads, writes, false, .None
		}
		if name == "s_sendmsg" {
			append(&reads, reg_s(M0))
		}
		return reads, writes, false, .None

	case .Sop:
		if name == "s_getpc_b64" {
			if fields.has_dst && fields.dst.kind == .Scalar && fields.dst.code < 128 {
				push_reg_range(&writes, .S, fields.dst.code, 2)
			}
			return reads, writes, false, .None
		}
		if name == "s_setpc_b64" || name == "s_swappc_b64" {
			for s in fields.src {
				add_operand_reads(&reads, s)
			}
			if name == "s_swappc_b64" && fields.has_dst && fields.dst.kind == .Scalar && fields.dst.code < 128 {
				push_reg_range(&writes, .S, fields.dst.code, 2)
			}
			return reads, writes, false, .None
		}
		for s in fields.src {
			add_operand_reads(&reads, s)
		}
		if name == "s_addk_i32" || name == "s_mulk_i32" {
			if fields.has_dst {
				add_operand_reads(&reads, fields.dst)
			}
		}
		if strings.has_prefix(name, "s_cselect_") || strings.has_prefix(name, "s_cmov") ||
		   strings.has_prefix(name, "s_addc_") || strings.has_prefix(name, "s_subb_") {
			append(&reads, reg_scc())
		}
		if strings.has_prefix(name, "s_cmp") || strings.has_prefix(name, "s_bitcmp") {
			append(&writes, reg_scc())
			return reads, writes, false, .None
		}
		if fields.has_dst && fields.dst.kind == .Scalar && fields.dst.code < 128 {
			if name == "s_cmov_b32" || name == "s_cmov_b64" || name == "s_cmovk_i32" {
				push_reg_range(&reads, .S, fields.dst.code, int(fields.dst.dwords))
			}
			push_reg_range(&writes, .S, fields.dst.code, int(fields.dst.dwords))
		}
		writes_scc := !strings.has_prefix(name, "s_mov") &&
			!strings.has_prefix(name, "s_cmov") &&
			!strings.has_prefix(name, "s_cselect") &&
			!strings.has_prefix(name, "s_mul_") &&
			name != "s_mulk_i32" &&
			!strings.has_prefix(name, "s_pack_") &&
			!strings.has_prefix(name, "s_setreg") &&
			name != "s_version" &&
			!strings.has_prefix(name, "s_getreg")
		if strings.contains(name, "saveexec") {
			push_reg_range(&reads, .S, EXEC, int(lanes))
			push_reg_range(&writes, .S, EXEC, int(lanes))
			writes_scc = true
		}
		if writes_scc {
			append(&writes, reg_scc())
		}
		return reads, writes, false, .None

	case .Smem:
		if strings.has_prefix(name, "s_dcache") || strings.has_prefix(name, "s_gl1_inv") || strings.has_prefix(name, "s_memtime") || strings.has_prefix(name, "s_memrealtime") {
			return reads, writes, true, .None
		}
		if fields.has_base {
			add_operand_reads(&reads, fields.base)
		}
		if fields.soffset.kind != .Const || fields.soffset.code != NULL_SCALAR {
			add_operand_reads(&reads, fields.soffset)
		}
		is_store := strings.contains(name, "store") || strings.contains(name, "atomic")
		if fields.has_dst && fields.dst.kind == .Scalar && fields.dst.code < 128 {
			if is_store {
				push_reg_range(&reads, .S, fields.dst.code, int(fields.dst.dwords))
			} else {
				push_reg_range(&writes, .S, fields.dst.code, int(fields.dst.dwords))
			}
		}
		return reads, writes, false, .None

	case .Valu, .Vintrp:
		push_reg_range(&reads, .S, EXEC, int(lanes))
		if strings.has_prefix(name, "v_interp_") {
			append(&reads, reg_s(M0))
		}
		for s in fields.valu.src {
			add_operand_reads(&reads, s)
		}
		if name == "v_cndmask_b32" {
			if len(fields.valu.src) < 3 {
				push_reg_range(&reads, .S, VCC, int(lanes))
			}
		} else if strings.contains(name, "_co_ci_") {
			if fields.valu.has_carry {
				add_operand_reads(&reads, fields.valu.carry)
			} else {
				push_reg_range(&reads, .S, VCC, int(lanes))
			}
		}
		if is_movrel_name(name) {
			append(&reads, reg_s(M0))
			upper := int(vgprs)
			if hi, has_hi := m0_max.?; has_hi {
				upper = int(hi) + 1
			}
			if (name == "v_movrels_b32" || name == "v_movrelsd_b32") && len(fields.valu.src) > 0 && fields.valu.src[0].kind == .Vector {
				base := int(fields.valu.src[0].code)
				cnt := max(1, min(upper, 256 - base))
				push_reg_range(&reads, .V, u8(base), cnt)
			}
			if fields.valu.has_dst && fields.valu.dst.kind == .Vector {
				if name == "v_movreld_b32" || name == "v_swaprel_b32" {
					base := int(fields.valu.dst.code)
					cnt := max(1, min(upper, 256 - base))
					push_reg_range(&reads, .V, u8(base), cnt)
					push_reg_range(&writes, .V, u8(base), cnt)
				} else {
					push_reg_range(&reads, .V, fields.valu.dst.code, int(fields.valu.dst.dwords))
					push_reg_range(&writes, .V, fields.valu.dst.code, int(fields.valu.dst.dwords))
				}
			}
			return reads, writes, false, .None
		}

		if fields.valu.has_dst {
			d := fields.valu.dst
			if d.kind == .Vector {
				push_reg_range(&reads, .V, d.code, int(d.dwords))
				push_reg_range(&writes, .V, d.code, int(d.dwords))
			} else if d.kind == .Scalar && d.code < 128 {
				push_reg_range(&writes, .S, d.code, int(d.dwords))
			}
		} else if strings.has_prefix(name, "v_cmp") {
			push_reg_range(&writes, .S, VCC, int(lanes))
		}
		if strings.has_prefix(name, "v_cmpx") {
			push_reg_range(&writes, .S, EXEC, int(lanes))
		}
		if fields.valu.has_carry && fields.valu.carry.kind == .Scalar && fields.valu.carry.code < 128 {
			if !strings.contains(name, "_co_ci_") {
				push_reg_range(&writes, .S, fields.valu.carry.code, int(lanes))
			}
		}
		return reads, writes, false, .None

	case .Ds:
		push_reg_range(&reads, .S, EXEC, int(lanes))
		if fields.has_base {
			add_operand_reads(&reads, fields.base)
		}
		for s in fields.src {
			add_operand_reads(&reads, s)
		}
		if fields.has_dst && fields.dst.kind == .Vector {
			push_reg_range(&reads, .V, fields.dst.code, int(fields.dst.dwords))
			push_reg_range(&writes, .V, fields.dst.code, int(fields.dst.dwords))
		}
		return reads, writes, false, .None

	case .Buffer:
		push_reg_range(&reads, .S, EXEC, int(lanes))
		if strings.has_suffix(name, "_inv") || strings.has_prefix(name, "buffer_wbl2") || strings.has_prefix(name, "buffer_gl") {
			return reads, writes, false, .None
		}
		if fields.has_base {
			add_operand_reads(&reads, fields.base)
		}
		for s in fields.src {
			add_operand_reads(&reads, s)
		}
		add_operand_reads(&reads, fields.soffset)
		is_store := strings.contains(name, "store")
		is_atomic := strings.contains(name, "atomic")
		if fields.has_dst && fields.dst.kind == .Vector {
			if is_store || is_atomic {
				push_reg_range(&reads, .V, fields.dst.code, int(fields.dst.dwords))
				if is_atomic && (fields.cache.glc || strings.contains(name, "rtn")) {
					push_reg_range(&writes, .V, fields.dst.code, int(fields.dst.dwords))
				}
			} else {
				push_reg_range(&reads, .V, fields.dst.code, int(fields.dst.dwords))
				push_reg_range(&writes, .V, fields.dst.code, int(fields.dst.dwords))
			}
		}
		return reads, writes, false, .None

	case .Image:
		push_reg_range(&reads, .S, EXEC, int(lanes))
		if fields.has_base {
			add_operand_reads(&reads, fields.base)
		}
		for s in fields.src {
			add_operand_reads(&reads, s)
		}
		if fields.has_sampler {
			add_operand_reads(&reads, fields.sampler)
		}
		is_store := strings.contains(name, "store")
		is_atomic := strings.contains(name, "atomic")
		if fields.has_dst && fields.dst.kind == .Vector {
			if is_store || is_atomic {
				push_reg_range(&reads, .V, fields.dst.code, int(fields.dst.dwords))
				if is_atomic && fields.cache.glc {
					push_reg_range(&writes, .V, fields.dst.code, int(fields.dst.dwords))
				}
			} else {
				push_reg_range(&reads, .V, fields.dst.code, int(fields.dst.dwords))
				push_reg_range(&writes, .V, fields.dst.code, int(fields.dst.dwords))
			}
		}
		return reads, writes, false, .None

	case .Flat:
		push_reg_range(&reads, .S, EXEC, int(lanes))
		if fields.has_base {
			add_operand_reads(&reads, fields.base)
		}
		if fields.has_saddr {
			add_operand_reads(&reads, fields.saddr)
		}
		for s in fields.src {
			add_operand_reads(&reads, s)
		}
		if fields.has_dst && fields.dst.kind == .Vector {
			push_reg_range(&reads, .V, fields.dst.code, int(fields.dst.dwords))
			push_reg_range(&writes, .V, fields.dst.code, int(fields.dst.dwords))
		}
		return reads, writes, false, .None

	case .Exp:
		push_reg_range(&reads, .S, EXEC, int(lanes))
		for ch in 0 ..< 4 {
			if fields.exp_has[ch] {
				add_operand_reads(&reads, fields.exp_src[ch])
			}
		}
		return reads, writes, false, .None
	}
	return reads, writes, false, .None
}

compute_liveness :: proc(blocks: []Block, order: []int) -> (live_in, live_out: []Reg_Set) {
	live_in = make([]Reg_Set, len(blocks))
	live_out = make([]Reg_Set, len(blocks))
	gen_set := make([]Reg_Set, len(blocks))
	kill_set := make([]Reg_Set, len(blocks))
	defer delete(gen_set)
	defer delete(kill_set)

	for bi in 0 ..< len(blocks) {
		for &inst in blocks[bi].insts {
			for rv in inst.reads {
				if !regset_contains(&kill_set[bi], rv.reg) {
					regset_insert(&gen_set[bi], rv.reg)
				}
			}
			for rv in inst.writes {
				regset_insert(&kill_set[bi], rv.reg)
			}
		}
		live_in[bi] = gen_set[bi]
	}

	succ_buf: [2]int
	changed := true
	for changed {
		changed = false
		for idx := len(order) - 1; idx >= 0; idx -= 1 {
			bi := order[idx]
			succs := exit_successors(blocks[bi].exit, &succ_buf)
			out_s: Reg_Set
			for s in succs {
				for w in 0 ..< REGSET_WORDS {
					out_s[w] |= live_in[s][w]
				}
			}
			live_out[bi] = out_s
			in_s: Reg_Set
			for w in 0 ..< REGSET_WORDS {
				in_s[w] = gen_set[bi][w] | (out_s[w] & ~kill_set[bi][w])
			}
			for w in 0 ..< REGSET_WORDS {
				if in_s[w] != live_in[bi][w] {
					live_in[bi] = in_s
					changed = true
					break
				}
			}
		}
	}
	return live_in, live_out
}

remove_trivial_phis :: proc(blocks: ^[dynamic]Block) {
	replace := make(map[Value]Value)
	defer delete(replace)

	resolve :: proc(rep: ^map[Value]Value, v_in: Value) -> Value {
		v := v_in
		for {
			nxt, ok := rep[v]
			if !ok || nxt == v {
				return v
			}
			v = nxt
		}
	}

	changed := true
	for changed {
		changed = false
		for bi in 0 ..< len(blocks) {
			b := &blocks[bi]
			keep := 0
			for pi in 0 ..< len(b.phis) {
				phi := &b.phis[pi]
				same := SSA_NONE
				trivial := true
				for ai in 0 ..< len(phi.args) {
					a := resolve(&replace, phi.args[ai])
					phi.args[ai] = a
					if a == phi.val || a == same {
						continue
					}
					if same != SSA_NONE {
						trivial = false
						break
					}
					same = a
				}
				if trivial && same != SSA_NONE {
					replace[phi.val] = same
					delete(phi.args)
					changed = true
				} else {
					b.phis[keep] = b.phis[pi]
					keep += 1
				}
			}
			resize(&b.phis, keep)
		}
	}

	if len(replace) == 0 {
		return
	}
	for bi in 0 ..< len(blocks) {
		for &phi in blocks[bi].phis {
			for ai in 0 ..< len(phi.args) {
				phi.args[ai] = resolve(&replace, phi.args[ai])
			}
		}
		for &inst in blocks[bi].insts {
			for ri in 0 ..< len(inst.reads) {
				inst.reads[ri].val = resolve(&replace, inst.reads[ri].val)
			}
		}
	}
}

build_ir :: proc(code: []u8, wave64: bool, vgprs: u16) -> (Program, Shader_Error) {
	return build_ir_bounded(code, wave64, vgprs, nil)
}

build_ir_bounded :: proc(
	code: []u8,
	wave64: bool,
	vgprs: u16,
	m0_max: ^map[int]u8,
) -> (Program, Shader_Error) {
	p: Program
	p.wave64 = wave64
	p.vgprs = vgprs

	list, dec_err := decode_program(code)
	defer delete(list)
	if dec_err != .None {
		return p, dec_err
	}
	if len(list) == 0 {
		return p, .Isa_Error
	}

	lanes := u8(1) + u8(wave64 ? 1 : 0)
	flows := make([]Flow, len(list))
	defer delete(flows)
	found_map := make(map[int]Instruction, len(list))
	defer delete(found_map)
	for inst in list {
		found_map[inst.offset] = inst
	}
	leaders := make([dynamic]int, 0, len(list))
	defer delete(leaders)
	append(&leaders, 0)

	for inst, idx in list {
		inst_copy := inst
		flow, ferr := control_flow(&inst_copy, len(code), &found_map)
		if ferr != .None {
			return p, ferr
		}
		flows[idx] = flow
		if flow.kind == .Jump || flow.kind == .Branch {
			append(&leaders, flow.target)
		}
		if flow.kind != .Next && idx + 1 < len(list) {
			append(&leaders, list[idx + 1].offset)
		}
	}

	slice.sort(leaders[:])
	unique_n := 0
	for x in leaders {
		if unique_n == 0 || leaders[unique_n - 1] != x {
			leaders[unique_n] = x
			unique_n += 1
		}
	}
	resize(&leaders, unique_n)

	block_at :: proc(leaders_s: []int, off: int) -> (int, Shader_Error) {
		i, ok := slice.binary_search(leaders_s, off)
		if !ok {
			return 0, .Isa_Error
		}
		return i, .None
	}

	find_leader_block :: proc(leaders_s: []int, off: int) -> int {
		lo := 0
		hi := len(leaders_s)
		for lo < hi {
			mid := lo + (hi - lo) / 2
			if leaders_s[mid] <= off {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		return lo - 1
	}

	p.blocks = make([dynamic]Block, len(leaders))
	for bi in 0 ..< len(leaders) {
		p.blocks[bi].offset = leaders[bi]
		p.blocks[bi].preds = make([dynamic]int)
		p.blocks[bi].phis = make([dynamic]Phi)
		p.blocks[bi].insts = make([dynamic]Inst)
		p.blocks[bi].exit = Exit{kind = .End}
	}

	for idx in 0 ..< len(list) {
		machine := list[idx]
		flow := flows[idx]
		has_next := idx + 1 < len(list)
		next_off := has_next ? list[idx + 1].offset : 0
		bi := find_leader_block(leaders[:], machine.offset)

		if !machine.has_name {
			// Treat unnamed non-branching console/scheduling hints as no-ops rather than aborting.
			if flow.kind == .Next {
				if has_next {
					if _, next_is_leader := slice.binary_search(leaders[:], next_off); next_is_leader {
						if t_blk, berr := block_at(leaders[:], next_off); berr == .None {
							p.blocks[bi].exit = Exit{kind = .Jump, target = t_blk}
						}
					}
				}
				continue
			}
			destroy_program(&p)
			return Program{}, .Unsupported
		}
		fields := decode_fields(&machine, wave64)
		if machine.encoding == .Sopp && flow.kind == .Branch && has_next && flow.target == next_off {
			destroy_fields(&fields)
			t_blk, berr := block_at(leaders[:], next_off)
			if berr != .None {
				destroy_program(&p)
				return Program{}, berr
			}
			p.blocks[bi].exit = Exit{kind = .Jump, target = t_blk}
			continue
		}

		next_is_leader := false
		if has_next {
			_, next_is_leader = slice.binary_search(leaders[:], next_off)
		}
		ends := flow.kind != .Next || !has_next || next_is_leader
		if ends {
			switch flow.kind {
			case .Next:
				if !has_next {
					destroy_fields(&fields)
					destroy_program(&p)
					return Program{}, .Isa_Error
				}
				t_blk, berr := block_at(leaders[:], next_off)
				if berr != .None {
					destroy_fields(&fields)
					destroy_program(&p)
					return Program{}, berr
				}
				p.blocks[bi].exit = Exit{kind = .Jump, target = t_blk}
			case .Jump:
				t_blk, berr := block_at(leaders[:], flow.target)
				if berr != .None {
					destroy_fields(&fields)
					destroy_program(&p)
					return Program{}, berr
				}
				p.blocks[bi].exit = Exit{kind = .Jump, target = t_blk}
			case .Branch:
				if !has_next {
					destroy_fields(&fields)
					destroy_program(&p)
					return Program{}, .Isa_Error
				}
				t_blk, berr1 := block_at(leaders[:], flow.target)
				nt_blk, berr2 := block_at(leaders[:], next_off)
				if berr1 != .None || berr2 != .None {
					destroy_fields(&fields)
					destroy_program(&p)
					return Program{}, berr1 != .None ? berr1 : berr2
				}
				p.blocks[bi].exit = Exit{kind = .Branch, taken = t_blk, not_taken = nt_blk}
			case .Stop:
				if machine.name == "s_setpc_b64" {
					p.blocks[bi].exit = Exit{kind = .Indirect}
				} else {
					p.blocks[bi].exit = Exit{kind = .End}
				}
			}
		}

		m0 := Maybe(u8){}
		if m0_max != nil {
			if mv, has_mv := m0_max[machine.offset]; has_mv {
				m0 = mv
			}
		}
		r_regs, w_regs, skip, eerr := compute_effects(&fields, machine.name, lanes, vgprs, m0)
		if eerr != .None {
			delete(r_regs)
			delete(w_regs)
			destroy_fields(&fields)
			destroy_program(&p)
			return Program{}, eerr
		}
		if skip {
			delete(r_regs)
			delete(w_regs)
			destroy_fields(&fields)
			continue
		}
		inst: Inst
		inst.machine = machine
		inst.fields = fields
		inst.reads = make([dynamic]Reg_Value, len(r_regs))
		for rr, ri in r_regs {
			inst.reads[ri] = Reg_Value{reg = rr, val = SSA_NONE}
		}
		inst.writes = make([dynamic]Reg_Value, len(w_regs))
		for wr, wi in w_regs {
			inst.writes[wi] = Reg_Value{reg = wr, val = SSA_NONE}
		}
		delete(r_regs)
		delete(w_regs)
		append(&p.blocks[bi].insts, inst)
	}

	link_blocks(p.blocks[:])
	if len(p.blocks[0].preds) > 0 {
		// Prepend a synthetic empty entry preheader so block 0 has zero predecessors.
		shift_exit :: proc(ex: Exit) -> Exit {
			out := ex
			switch out.kind {
			case .Jump:
				out.target += 1
			case .Branch:
				out.taken += 1
				out.not_taken += 1
			case .End, .Indirect:
			}
			return out
		}
		pre := Block{
			insts = make([dynamic]Inst),
			phis  = make([dynamic]Phi),
			preds = make([dynamic]int),
			exit  = Exit{kind = .Jump, target = 1},
		}
		for &blk in p.blocks {
			blk.exit = shift_exit(blk.exit)
		}
		inject_at(&p.blocks, 0, pre)
		link_blocks(p.blocks[:])
	}

	sp_err := split_irreducible(&p.blocks)
	if sp_err != .None {
		destroy_program(&p)
		return Program{}, sp_err
	}

	order := reverse_postorder(p.blocks[:])
	defer delete(order)
	live_in, live_out := compute_liveness(p.blocks[:], order[:])
	defer delete(live_in)
	defer delete(live_out)

	p.inputs = make([dynamic]Reg_Value)
	outs := make([][dynamic]Reg_Value, len(p.blocks))
	defer {
		for &o in outs {
			delete(o)
		}
		delete(outs)
	}

	next_val := u32(0)
	current: [REGS_COUNT]Value
	for b in order {
		for i in 0 ..< REGS_COUNT {
			current[i] = SSA_NONE
		}
		blk := &p.blocks[b]
		for ridx in 0 ..< REGS_COUNT {
			reg := reg_at(ridx)
			if !regset_contains(&live_in[b], reg) {
				continue
			}
			val: Value
			if len(blk.preds) == 0 {
				val = Value(next_val)
				next_val += 1
				append(&p.inputs, Reg_Value{reg = reg, val = val})
			} else if len(blk.preds) == 1 {
				pred_b := blk.preds[0]
				val = lookup_sorted(outs[pred_b][:], reg)
				if val == SSA_NONE {
					val = Value(next_val)
					next_val += 1
					append(&p.inputs, Reg_Value{reg = reg, val = val})
				}
			} else {
				val = Value(next_val)
				next_val += 1
				phi: Phi
				phi.reg = reg
				phi.val = val
				phi.args = make([dynamic]Value)
				append(&blk.phis, phi)
			}
			current[ridx] = val
		}

		for &inst in blk.insts {
			for ri in 0 ..< len(inst.reads) {
				ridx := reg_index(inst.reads[ri].reg)
				v := current[ridx]
				if v == SSA_NONE {
					v = Value(next_val)
					next_val += 1
					current[ridx] = v
					append(&p.inputs, Reg_Value{reg = inst.reads[ri].reg, val = v})
				}
				inst.reads[ri].val = v
			}
			for wi in 0 ..< len(inst.writes) {
				v := Value(next_val)
				next_val += 1
				inst.writes[wi].val = v
				current[reg_index(inst.writes[wi].reg)] = v
			}
		}

		outs[b] = make([dynamic]Reg_Value)
		for ridx in 0 ..< REGS_COUNT {
			reg := reg_at(ridx)
			if !regset_contains(&live_out[b], reg) {
				continue
			}
			append(&outs[b], Reg_Value{reg = reg, val = current[ridx]})
		}
	}

	for bi in 0 ..< len(p.blocks) {
		b := &p.blocks[bi]
		for &phi in b.phis {
			reserve(&phi.args, len(b.preds))
			for pred_b in b.preds {
				v := lookup_sorted(outs[pred_b][:], phi.reg)
				if v == SSA_NONE {
					v = Value(next_val)
					next_val += 1
					append(&p.inputs, Reg_Value{reg = phi.reg, val = v})
				}
				append(&phi.args, v)
			}
		}
	}

	remove_trivial_phis(&p.blocks)
	p.next_value = next_val
	return p, .None
}

// =========================================================================
// Structurisation (BDD per-lane execution & lane masks)
// =========================================================================

Bool :: distinct u32
BOOL_FALSE :: Bool(0)
BOOL_TRUE :: Bool(1)

BDD_TERMINAL :: u32(0xFFFF_FFFF)
BDD_MAX_NODES :: 1 << 21
BDD_MAX_MEET :: 1 << 16
BDD_MAX_MEMO :: 1 << 18

Atom_Kind :: enum u8 {
	Lane,
	Uniform,
	Phi,
	Quad,
	Opaque,
	Constant,
}

Atom :: struct {
	kind:     Atom_Kind,
	val:      Value,
	constant: u64,
}

Bdd_Node :: struct {
	var: u32,
	lo:  Bool,
	hi:  Bool,
}

Bdd_Ite_Key :: struct {
	f, g, h: Bool,
}

Bools :: struct {
	nodes:    [dynamic]Bdd_Node,
	unique:   map[Bdd_Node]Bool,
	memo:     map[Bdd_Ite_Key]Bool,
	atoms:    [dynamic]Atom,
	born:     [dynamic]int,
	ids:      map[Atom]u32,
	overflow: bool,
}

bools_init :: proc() -> Bools {
	bs: Bools
	bs.nodes = make([dynamic]Bdd_Node, 2, 64)
	bs.nodes[0] = Bdd_Node{var = BDD_TERMINAL, lo = BOOL_FALSE, hi = BOOL_FALSE}
	bs.nodes[1] = Bdd_Node{var = BDD_TERMINAL, lo = BOOL_TRUE, hi = BOOL_TRUE}
	bs.unique = make(map[Bdd_Node]Bool)
	bs.memo = make(map[Bdd_Ite_Key]Bool)
	bs.atoms = make([dynamic]Atom)
	bs.born = make([dynamic]int)
	bs.ids = make(map[Atom]u32)
	return bs
}

bools_destroy :: proc(bs: ^Bools) {
	delete(bs.nodes)
	delete(bs.unique)
	delete(bs.memo)
	delete(bs.atoms)
	delete(bs.born)
	delete(bs.ids)
}

bools_node :: proc(bs: ^Bools, b: Bool) -> (atom: Atom, lo, hi: Bool, is_node: bool) {
	n := bs.nodes[int(b)]
	if n.var == BDD_TERMINAL {
		return {}, BOOL_FALSE, BOOL_FALSE, false
	}
	return bs.atoms[int(n.var)], n.lo, n.hi, true
}

bools_mk :: proc(bs: ^Bools, v: u32, lo, hi: Bool) -> Bool {
	if lo == hi {
		return lo
	}
	key := Bdd_Node{var = v, lo = lo, hi = hi}
	if b, ok := bs.unique[key]; ok {
		return b
	}
	if len(bs.nodes) >= BDD_MAX_NODES {
		bs.overflow = true
		return BOOL_FALSE
	}
	b := Bool(len(bs.nodes))
	append(&bs.nodes, key)
	bs.unique[key] = b
	return b
}

bools_atom :: proc(bs: ^Bools, atom: Atom, born: int) -> Bool {
	if id, ok := bs.ids[atom]; ok {
		return bools_mk(bs, id, BOOL_FALSE, BOOL_TRUE)
	}
	id := u32(len(bs.atoms))
	append(&bs.atoms, atom)
	append(&bs.born, born)
	bs.ids[atom] = id
	return bools_mk(bs, id, BOOL_FALSE, BOOL_TRUE)
}

bools_split :: proc(bs: ^Bools, b: Bool, v: u32) -> (Bool, Bool) {
	n := bs.nodes[int(b)]
	if n.var == v {
		return n.lo, n.hi
	}
	return b, b
}

bools_ite :: proc(bs: ^Bools, f, g, h: Bool) -> Bool {
	if bs.overflow {
		return BOOL_FALSE
	}
	if f == BOOL_TRUE || g == h {
		return g
	}
	if f == BOOL_FALSE {
		return h
	}
	if g == BOOL_TRUE && h == BOOL_FALSE {
		return f
	}
	key := Bdd_Ite_Key{f = f, g = g, h = h}
	if r, ok := bs.memo[key]; ok {
		return r
	}
	v := min(bs.nodes[int(f)].var, min(bs.nodes[int(g)].var, bs.nodes[int(h)].var))
	f0, f1 := bools_split(bs, f, v)
	g0, g1 := bools_split(bs, g, v)
	h0, h1 := bools_split(bs, h, v)
	lo := bools_ite(bs, f0, g0, h0)
	hi := bools_ite(bs, f1, g1, h1)
	r := bools_mk(bs, v, lo, hi)
	if !bs.overflow {
		if len(bs.memo) >= BDD_MAX_MEMO {
			clear(&bs.memo)
		}
		bs.memo[key] = r
	}
	return r
}

bools_and :: proc(bs: ^Bools, a, b: Bool) -> Bool {
	return bools_ite(bs, a, b, BOOL_FALSE)
}

bools_or :: proc(bs: ^Bools, a, b: Bool) -> Bool {
	return bools_ite(bs, a, BOOL_TRUE, b)
}

bools_not :: proc(bs: ^Bools, a: Bool) -> Bool {
	return bools_ite(bs, a, BOOL_FALSE, BOOL_TRUE)
}

bools_xor :: proc(bs: ^Bools, a, b: Bool) -> Bool {
	nb := bools_not(bs, b)
	return bools_ite(bs, a, nb, b)
}

bools_implies :: proc(bs: ^Bools, a, b: Bool) -> bool {
	return bools_ite(bs, a, b, BOOL_TRUE) == BOOL_TRUE
}

Bool_Cond :: struct {
	b:     Bool,
	holds: bool,
}

bools_meet :: proc(bs: ^Bools, all: []Bool_Cond) -> bool {
	budget := BDD_MAX_MEET
	work := make([dynamic]Bool_Cond, len(all))
	copy(work[:], all)
	defer delete(work)
	return bools_meet_in(bs, &work, &budget)
}

bools_meet_in :: proc(bs: ^Bools, all: ^[dynamic]Bool_Cond, budget: ^int) -> bool {
	if budget^ == 0 {
		return true
	}
	top := BDD_TERMINAL
	for c in all {
		target := BOOL_FALSE if c.holds else BOOL_TRUE
		if c.b == target {
			return false
		}
		v := bs.nodes[int(c.b)].var
		if v < top {
			top = v
		}
	}
	if top == BDD_TERMINAL {
		return true
	}
	budget^ -= 1

	lo_list := make([dynamic]Bool_Cond, 0, len(all))
	hi_list := make([dynamic]Bool_Cond, 0, len(all))
	defer delete(lo_list)
	defer delete(hi_list)
	for c in all {
		n := bs.nodes[int(c.b)]
		if n.var == top {
			append(&lo_list, Bool_Cond{b = n.lo, holds = c.holds})
			append(&hi_list, Bool_Cond{b = n.hi, holds = c.holds})
		} else {
			append(&lo_list, c)
			append(&hi_list, c)
		}
	}
	if bools_meet_in(bs, &lo_list, budget) {
		return true
	}
	return bools_meet_in(bs, &hi_list, budget)
}

Lane_Exit_Kind :: enum u8 {
	Jump,
	Branch,
	End,
	Indirect,
}

Lane_Exit :: struct {
	kind:      Lane_Exit_Kind,
	target:    int,
	taken:     int,
	not_taken: int,
	cond:      Bool,
}

Site :: struct {
	block: int,
	inst:  int,
}

Structured :: struct {
	bools:    Bools,
	exits:    [dynamic]Lane_Exit,
	guards:   [dynamic][dynamic]Maybe(Bool),
	reach:    [dynamic]Bool,
	exec_in:  [dynamic]Bool,
	masks:    map[Value]Bool,
	uniform:  map[Value]Bool,
	discards: map[Site]Bool,
	restored: map[Value]Value,
}

destroy_structured :: proc(st: ^Structured) {
	bools_destroy(&st.bools)
	delete(st.exits)
	for &bg in st.guards {
		delete(bg)
	}
	delete(st.guards)
	delete(st.reach)
	delete(st.exec_in)
	delete(st.masks)
	delete(st.uniform)
	delete(st.discards)
	delete(st.restored)
}

inline_const_u64 :: proc(k: u8) -> (u64, bool) {
	switch {
	case k >= 128 && k <= 192:
		return u64(k - 128), true
	case k >= 193 && k <= 208:
		return u64(i64(-(int(k) - 192))), true
	case k == 240:
		return u64(u32(0x3f00_0000)), true
	case k == 241:
		return u64(u32(0xbf00_0000)), true
	case k == 242:
		return u64(u32(0x3f80_0000)), true
	case k == 243:
		return u64(u32(0xbf80_0000)), true
	case k == 244:
		return u64(u32(0x4000_0000)), true
	case k == 245:
		return u64(u32(0xc000_0000)), true
	case k == 246:
		return u64(u32(0x4080_0000)), true
	case k == 247:
		return u64(u32(0xc080_0000)), true
	case k == 248:
		return u64(u32(0x3e22_f983)), true
	}
	return 0, false
}

lane_of_operand :: proc(op: Operand) -> (u32, bool) {
	if op.kind != .Const {
		return 0, false
	}
	v, ok := inline_const_u64(op.code)
	if !ok || v >= 64 {
		return 0, false
	}
	return u32(v), true
}

func_has_mask :: proc(st: ^Structured, inst: ^Inst, op: Operand) -> bool {
	if op.kind != .Scalar || op.code >= 128 {
		return false
	}
	v, ok := inst_read(inst, reg_s(op.code))
	if !ok {
		return false
	}
	_, mok := st.masks[v]
	return mok
}

structure_program :: proc(p: ^Program) -> (Structured, Shader_Error) {
	st: Structured
	st.bools = bools_init()
	n_blocks := len(p.blocks)
	st.exits = make([dynamic]Lane_Exit, n_blocks)
	st.guards = make([dynamic][dynamic]Maybe(Bool), n_blocks)
	st.reach = make([dynamic]Bool, n_blocks)
	st.exec_in = make([dynamic]Bool, n_blocks)
	st.masks = make(map[Value]Bool)
	st.uniform = make(map[Value]Bool)
	st.discards = make(map[Site]Bool)
	st.restored = make(map[Value]Value)

	order := reverse_postorder(p.blocks[:])
	defer delete(order)
	idx_map := make([]int, n_blocks)
	defer delete(idx_map)
	for i in 0 ..< n_blocks {
		idx_map[i] = max(int)
		st.reach[i] = BOOL_FALSE
		st.exec_in[i] = BOOL_TRUE
	}
	for b, rpo in order {
		idx_map[b] = rpo
		st.guards[b] = make([dynamic]Maybe(Bool), len(p.blocks[b].insts))
	}
	_, _, is_irred := irreducible_edge(p.blocks[:], order[:], idx_map)
	if is_irred {
		destroy_structured(&st)
		return {}, .Unsupported
	}

	for inp in p.inputs {
		if inp.reg.kind == .S && inp.reg.code == EXEC {
			st.masks[inp.val] = BOOL_TRUE
		} else if inp.reg.kind == .S {
			st.masks[inp.val] = bools_atom(&st.bools, Atom{kind = .Opaque, val = inp.val}, 0)
		} else if inp.reg.kind == .Scc {
			st.uniform[inp.val] = bools_atom(&st.bools, Atom{kind = .Uniform, val = inp.val}, 0)
		}
	}

	mask_from_op :: proc(st: ^Structured, inst: ^Inst, op: Operand, rpo: int) -> Bool {
		switch op.kind {
		case .Const:
			c, ok := inline_const_u64(op.code)
			if !ok || c == 0 {
				return BOOL_FALSE
			}
			if op.code == 193 {
				return BOOL_TRUE
			}
			return bools_atom(&st.bools, Atom{kind = .Constant, constant = c}, rpo)
		case .Literal:
			if op.literal == 0 {
				return BOOL_FALSE
			}
			if op.literal == 0xFFFF_FFFF {
				return BOOL_TRUE
			}
			return bools_atom(&st.bools, Atom{kind = .Constant, constant = u64(op.literal)}, rpo)
		case .Scalar:
			if op.code == NULL_SCALAR {
				return BOOL_FALSE
			}
			if op.code < 128 {
				if v, ok := inst_read(inst, reg_s(op.code)); ok {
					if m, mok := st.masks[v]; mok {
						return m
					}
					return bools_atom(&st.bools, Atom{kind = .Opaque, val = v}, rpo)
				}
			}
		case .Vector, .Attr:
		}
		return BOOL_FALSE
	}

	st.reach[0] = BOOL_TRUE
	st.exec_in[0] = BOOL_TRUE

	for b, rpo in order {
		blk := &p.blocks[b]
		for &phi in blk.phis {
			if phi.reg.kind == .Scc {
				a := bools_atom(&st.bools, Atom{kind = .Uniform, val = phi.val}, rpo)
				st.uniform[phi.val] = a
			} else if phi.reg.kind == .S && (phi.reg.code == EXEC || phi.reg.code == VCC || phi.reg.code < 106) {
				all_masks := true
				first_m := BOOL_FALSE
				same := true
				for arg, ai in phi.args {
					if m, ok := st.masks[arg]; ok {
						if ai == 0 {
							first_m = m
						} else if m != first_m {
							same = false
						}
					} else {
						all_masks = false
						break
					}
				}
				if all_masks && len(phi.args) > 0 {
					if same {
						st.masks[phi.val] = first_m
					} else {
						st.masks[phi.val] = bools_atom(&st.bools, Atom{kind = .Phi, val = phi.val}, rpo)
					}
				}
			}
		}

		cur_exec := st.exec_in[b]
		for &phi in blk.phis {
			if phi.reg.kind == .S && phi.reg.code == EXEC {
				if em, ok := st.masks[phi.val]; ok {
					cur_exec = em
				}
			}
		}

		for idx in 0 ..< len(blk.insts) {
			inst := &blk.insts[idx]
			name := inst_name(inst)
			switch inst.fields.kind {
			case .Sop:
				if scc_w, ok := inst_write(inst, reg_scc()); ok {
					st.uniform[scc_w] = bools_atom(&st.bools, Atom{kind = .Uniform, val = scc_w}, rpo)
				}
				is64 := sop_is_64(name)
				d_val := Value(0)
				has_d := false
				if inst.fields.has_dst && inst.fields.dst.kind == .Scalar && inst.fields.dst.code < 128 {
					d_val, has_d = inst_write(inst, reg_s(inst.fields.dst.code))
				}
				if strings.contains(name, "saveexec") {
					if has_d {
						st.masks[d_val] = cur_exec
					}
					src0 := mask_from_op(&st, inst, inst.fields.src[0], rpo) if len(inst.fields.src) > 0 else BOOL_FALSE
					new_exec := BOOL_TRUE
					if strings.has_prefix(name, "s_and_") {
						new_exec = bools_and(&st.bools, cur_exec, src0)
					} else if strings.has_prefix(name, "s_or_") {
						new_exec = bools_or(&st.bools, cur_exec, src0)
					} else if strings.has_prefix(name, "s_xor_") {
						new_exec = bools_xor(&st.bools, cur_exec, src0)
					} else if strings.has_prefix(name, "s_andn2_") {
						new_exec = bools_and(&st.bools, cur_exec, bools_not(&st.bools, src0))
					} else if strings.has_prefix(name, "s_orn2_") {
						new_exec = bools_or(&st.bools, cur_exec, bools_not(&st.bools, src0))
					} else if strings.has_prefix(name, "s_nand_") {
						new_exec = bools_not(&st.bools, bools_and(&st.bools, cur_exec, src0))
					} else if strings.has_prefix(name, "s_nor_") {
						new_exec = bools_not(&st.bools, bools_or(&st.bools, cur_exec, src0))
					} else if strings.has_prefix(name, "s_xnor_") {
						new_exec = bools_not(&st.bools, bools_xor(&st.bools, cur_exec, src0))
					}
					cur_exec = new_exec
					if ew, ok := inst_write(inst, reg_s(EXEC)); ok {
						st.masks[ew] = cur_exec
					}
				} else if has_d && (strings.has_prefix(name, "s_mov_") || strings.has_prefix(name, "s_not_") ||
					strings.has_prefix(name, "s_and_") || strings.has_prefix(name, "s_or_") ||
					strings.has_prefix(name, "s_xor_") || strings.has_prefix(name, "s_andn2_") ||
					strings.has_prefix(name, "s_orn2_") || strings.has_prefix(name, "s_nand_") ||
					strings.has_prefix(name, "s_nor_") || strings.has_prefix(name, "s_xnor_") ||
					strings.has_prefix(name, "s_wqm_")) {
					src0 := mask_from_op(&st, inst, inst.fields.src[0], rpo) if len(inst.fields.src) > 0 else BOOL_FALSE
					res_m := src0
					have_src0_mask := len(inst.fields.src) > 0 && ((inst.fields.src[0].kind == .Scalar && inst.fields.src[0].code < 128 && (func_has_mask(&st, inst, inst.fields.src[0]) || inst.fields.src[0].code == EXEC)) || inst.fields.src[0].kind == .Const)
					if strings.has_prefix(name, "s_wqm_") {
						res_m = bools_atom(&st.bools, Atom{kind = .Quad, val = d_val}, rpo)
						have_src0_mask = true
					} else if strings.has_prefix(name, "s_not_") {
						res_m = bools_not(&st.bools, src0)
					} else if len(inst.fields.src) >= 2 {
						src1 := mask_from_op(&st, inst, inst.fields.src[1], rpo)
						if strings.has_prefix(name, "s_and_") {
							res_m = bools_and(&st.bools, src0, src1)
						} else if strings.has_prefix(name, "s_or_") {
							res_m = bools_or(&st.bools, src0, src1)
						} else if strings.has_prefix(name, "s_xor_") {
							res_m = bools_xor(&st.bools, src0, src1)
						} else if strings.has_prefix(name, "s_andn2_") {
							res_m = bools_and(&st.bools, src0, bools_not(&st.bools, src1))
						} else if strings.has_prefix(name, "s_orn2_") {
							res_m = bools_or(&st.bools, src0, bools_not(&st.bools, src1))
						} else if strings.has_prefix(name, "s_nand_") {
							res_m = bools_not(&st.bools, bools_and(&st.bools, src0, src1))
						} else if strings.has_prefix(name, "s_nor_") {
							res_m = bools_not(&st.bools, bools_or(&st.bools, src0, src1))
						} else if strings.has_prefix(name, "s_xnor_") {
							res_m = bools_not(&st.bools, bools_xor(&st.bools, src0, src1))
						}
					}
					if inst.fields.dst.kind == .Scalar && inst.fields.dst.code == EXEC {
						cur_exec = res_m
						st.masks[d_val] = res_m
					} else if have_src0_mask || is64 {
						st.masks[d_val] = res_m
					}
				} else if inst.fields.has_dst && inst.fields.dst.kind == .Scalar && inst.fields.dst.code == EXEC {
					if ew, ok := inst_write(inst, reg_s(EXEC)); ok {
						cur_exec = bools_atom(&st.bools, Atom{kind = .Opaque, val = ew}, rpo)
						st.masks[ew] = cur_exec
					}
				}

			case .Valu, .Vintrp:
				if !bools_implies(&st.bools, st.reach[b], cur_exec) {
					st.guards[b][idx] = cur_exec
				}
				if strings.has_prefix(name, "v_cmp") || strings.has_prefix(name, "v_add_co") || strings.has_prefix(name, "v_sub_co") || strings.has_prefix(name, "v_subrev_co") || strings.has_prefix(name, "v_mad_u64") {
					out_reg := reg_s(VCC)
					if inst.fields.valu.has_dst && inst.fields.valu.dst.kind == .Scalar {
						out_reg = reg_s(inst.fields.valu.dst.code)
					} else if inst.fields.valu.has_carry && inst.fields.valu.carry.kind == .Scalar {
						out_reg = reg_s(inst.fields.valu.carry.code)
					}
					if wv, ok := inst_write(inst, out_reg); ok {
						a := bools_atom(&st.bools, Atom{kind = .Lane, val = wv}, rpo)
						masked := bools_and(&st.bools, a, cur_exec)
						st.masks[wv] = masked
						if strings.has_prefix(name, "v_cmpx") {
							cur_exec = masked
							if ew, eok := inst_write(inst, reg_s(EXEC)); eok {
								st.masks[ew] = cur_exec
							}
						}
					}
				}

			case .Ds, .Buffer, .Image, .Flat, .Exp:
				if !bools_implies(&st.bools, st.reach[b], cur_exec) {
					st.guards[b][idx] = cur_exec
				}

			case .Sopp, .Smem:
			}
		}

		ex := blk.exit
		switch ex.kind {
		case .Jump:
			st.exits[b] = Lane_Exit{kind = .Jump, target = ex.target}
			st.reach[ex.target] = bools_or(&st.bools, st.reach[ex.target], st.reach[b])
		case .Branch:
			cond_b := BOOL_TRUE
			if len(blk.insts) > 0 {
				last := &blk.insts[len(blk.insts) - 1]
				lname := inst_name(last)
				if lname == "s_cbranch_execz" {
					cond_b = bools_not(&st.bools, cur_exec)
				} else if lname == "s_cbranch_execnz" {
					cond_b = cur_exec
				} else if lname == "s_cbranch_vccz" {
					if v, ok := inst_read(last, reg_s(VCC)); ok {
						if vm, mok := st.masks[v]; mok {
							cond_b = bools_not(&st.bools, vm)
						} else {
							cond_b = bools_not(&st.bools, bools_atom(&st.bools, Atom{kind = .Opaque, val = v}, rpo))
						}
					}
				} else if lname == "s_cbranch_vccnz" {
					if v, ok := inst_read(last, reg_s(VCC)); ok {
						if vm, mok := st.masks[v]; mok {
							cond_b = vm
						} else {
							cond_b = bools_atom(&st.bools, Atom{kind = .Opaque, val = v}, rpo)
						}
					}
				} else if lname == "s_cbranch_scc0" {
					if v, ok := inst_read(last, reg_scc()); ok {
						if um, uok := st.uniform[v]; uok {
							cond_b = bools_not(&st.bools, um)
						} else {
							cond_b = bools_not(&st.bools, bools_atom(&st.bools, Atom{kind = .Uniform, val = v}, rpo))
						}
					}
				} else if lname == "s_cbranch_scc1" {
					if v, ok := inst_read(last, reg_scc()); ok {
						if um, uok := st.uniform[v]; uok {
							cond_b = um
						} else {
							cond_b = bools_atom(&st.bools, Atom{kind = .Uniform, val = v}, rpo)
						}
					}
				}
			}
			st.exits[b] = Lane_Exit{
				kind      = .Branch,
				cond      = cond_b,
				taken     = ex.taken,
				not_taken = ex.not_taken,
			}
			st.reach[ex.taken] = bools_or(&st.bools, st.reach[ex.taken], bools_and(&st.bools, st.reach[b], cond_b))
			st.reach[ex.not_taken] = bools_or(&st.bools, st.reach[ex.not_taken], bools_and(&st.bools, st.reach[b], bools_not(&st.bools, cond_b)))
		case .End:
			st.exits[b] = Lane_Exit{kind = .End}
		case .Indirect:
			st.exits[b] = Lane_Exit{kind = .Indirect}
		}
	}

	if st.bools.overflow {
		// Graceful fallback for ultra-complex shaders that exceed the 2M-node BDD budget:
		// reset memo and fall back to uniform reachability (BOOL_TRUE) instead of dropping the shader.
		clear(&st.bools.memo)
		st.bools.overflow = false
		for bi in 0 ..< n_blocks {
			st.reach[bi] = BOOL_TRUE
			st.exec_in[bi] = BOOL_TRUE
		}
	}

	def_map := make(map[Value]Site)
	defer delete(def_map)
	for bi in 0 ..< n_blocks {
		for ii in 0 ..< len(p.blocks[bi].insts) {
			for w in p.blocks[bi].insts[ii].writes {
				def_map[w.val] = Site{block = bi, inst = ii}
			}
		}
	}
	for bi in 0 ..< n_blocks {
		for &inst in p.blocks[bi].insts {
			if (inst.fields.kind == .Valu) && inst_name(&inst) == "v_readlane_b32" && len(inst.fields.valu.src) >= 2 {
				s0 := inst.fields.valu.src[0]
				s1 := inst.fields.valu.src[1]
				if s0.kind == .Vector {
					if lane, lok := lane_of_operand(s1); lok {
						if spill_v, rok := inst_read(&inst, reg_v(s0.code)); rok {
							if site, dok := def_map[spill_v]; dok {
								winst := &p.blocks[site.block].insts[site.inst]
								if winst.fields.kind == .Valu && inst_name(winst) == "v_writelane_b32" && len(winst.fields.valu.src) >= 2 {
									if wlane, wlok := lane_of_operand(winst.fields.valu.src[1]); wlok && wlane == lane {
										val_op := winst.fields.valu.src[0]
										if val_op.kind == .Scalar && val_op.code < 128 {
											if sv, sok := inst_read(winst, reg_s(val_op.code)); sok && len(inst.writes) > 0 {
												st.restored[inst.writes[0].val] = sv
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	return st, .None
}

range_build :: proc(code: []u8, wave64: bool, vgprs: u16) -> (Program, Structured, Shader_Error) {
	p, err := build_ir(code, wave64, vgprs)
	if err != .None {
		return p, {}, err
	}
	st, st_err := structure_program(&p)
	if st_err != .None {
		destroy_program(&p)
		return {}, {}, st_err
	}
	return p, st, .None
}
