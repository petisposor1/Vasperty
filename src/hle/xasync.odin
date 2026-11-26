package vasperty_hle

import "base:intrinsics"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

// COM runtime object & XTaskQueue / XAsyncBlock runtime (xasync + xgameruntime).

PROVIDER_XASYNC :: Guid{0x073b7dcb, 0x1fcf, 0x4030, {0x94, 0xbe, 0xe3, 0xc9, 0xeb, 0x62, 0x34, 0x28}}

Runtime_Object :: struct {
	vtable: rawptr,
	area:   string,
}

rt_add_ref :: proc "system" (_: ^Runtime_Object) -> u32 {
	context = hle_context()
	return 1
}

rt_missing :: proc "system" (_: ^Runtime_Object) -> HRESULT {
	context = hle_context()
	return E_NOTIMPL
}

put_ptr :: proc(out: ^$T, value: T) -> HRESULT {
	if out == nil {
		return E_INVALIDARG
	}
	out^ = value
	return S_OK
}

put_string :: proc(text: string, size: uint, buffer: [^]u8, used: ^uint) -> HRESULT {
	needed := len(text) + 1
	if buffer == nil || size < uint(needed) {
		return E_NOT_SUFFICIENT_BUFFER
	}
	if len(text) > 0 {
		mem.copy(buffer, raw_data(text), len(text))
	}
	buffer[len(text)] = 0
	if used != nil {
		used^ = uint(needed)
	}
	return S_OK
}

cstr_to_string :: proc(p: cstring) -> (string, bool) {
	if p == nil {
		return "", false
	}
	return string(p), true
}

@(private)
g_next_token: u64 = 1

next_token :: proc() -> u64 {
	return intrinsics.atomic_add(&g_next_token, 1)
}

// --- XTaskQueue / XAsyncBlock ---

XASYNC_WORK_PORT :: u32(0)
XASYNC_COMPLETION_PORT :: u32(1)
XASYNC_INFINITE :: u32(0xFFFFFFFF)

Queue_Mode :: enum u32 {
	Manual      = 0,
	Thread_Pool = 1,
	Serialized  = 2,
	Immediate   = 3,
}

Task_Callback :: #type proc "system" (ctx: rawptr, canceled: bool)
Monitor_Callback :: #type proc "system" (ctx: rawptr, queue: ^Task_Queue, port: u32)
Terminated_Callback :: #type proc "system" (ctx: rawptr)
Async_Completion_Routine :: #type proc "system" (block: ^Async_Block)
Async_Work :: #type proc "system" (block: ^Async_Block) -> HRESULT
Async_Provider :: #type proc "system" (op: u32, data: ^Provider_Data) -> HRESULT

XASYNC_OP_BEGIN :: u32(0)
XASYNC_OP_DO_WORK :: u32(1)
XASYNC_OP_GET_RESULT :: u32(2)
XASYNC_OP_CANCEL :: u32(3)
XASYNC_OP_CLEANUP :: u32(4)

Async_Block :: struct {
	queue:    ^Task_Queue,
	context_: rawptr,
	callback: Async_Completion_Routine,
	internal: [32]u8,
}

Provider_Data :: struct {
	block:       ^Async_Block,
	context_:    rawptr,
	identity:    rawptr,
	buffer_size: uint,
	buffer:      rawptr,
	internal:    rawptr,
}

Queued_Task :: struct {
	callback: Task_Callback,
	ctx:      rawptr,
}

Task_Port :: struct {
	mu:         sync.Mutex,
	cond:       sync.Cond,
	mode:       Queue_Mode,
	tasks:      [dynamic]Queued_Task,
	closed:     bool,
	terminated: bool,
	refs:       i32,
	workers:    [dynamic]^thread.Thread,
}

Monitor_Entry :: struct {
	token:    u64,
	ctx:      rawptr,
	callback: Monitor_Callback,
}

Task_Queue :: struct {
	mu:         sync.Mutex,
	refs:       i32,
	work:       ^Task_Port,
	completion: ^Task_Port,
	terminated: bool,
	monitors:   [dynamic]Monitor_Entry,
}

Async_Entry :: struct {
	id:          u64,
	identity:    rawptr,
	status:      HRESULT,
	completed:   bool,
	canceled:    bool,
	payload:     []u8,
	owns_mem:    bool,
	result_size: uint,
}

@(private)
xasync_state: struct {
	mu:            sync.Mutex,
	cond:          sync.Cond,
	next_id:       u64,
	blocks:        map[uintptr]^Async_Entry,
	process_queue: ^Task_Queue,
	queues:        [dynamic]^Task_Queue,
	ports:         [dynamic]^Task_Port,
}

@(private)
init_xasync_if_needed :: proc() {
	sync.mutex_lock(&xasync_state.mu)
	defer sync.mutex_unlock(&xasync_state.mu)
	if xasync_state.blocks == nil {
		xasync_state.blocks = make(map[uintptr]^Async_Entry)
		xasync_state.next_id = 1
	}
}

fini_xasync :: proc() {
	sync.mutex_lock(&xasync_state.mu)
	if xasync_state.blocks == nil {
		sync.mutex_unlock(&xasync_state.mu)
		return
	}
	pq := xasync_state.process_queue
	xasync_state.process_queue = nil

	// Mark all ports closed and wake workers.
	ports_copy := make([dynamic]^Task_Port, 0, len(xasync_state.ports))
	for p in xasync_state.ports {
		append(&ports_copy, p)
	}
	queues_copy := make([dynamic]^Task_Queue, 0, len(xasync_state.queues))
	for q in xasync_state.queues {
		append(&queues_copy, q)
	}
	clear(&xasync_state.ports)
	clear(&xasync_state.queues)

	for _, e in xasync_state.blocks {
		if e.owns_mem && len(e.payload) > 0 {
			delete(e.payload)
		}
		free(e)
	}
	delete(xasync_state.blocks)
	delete(xasync_state.ports)
	delete(xasync_state.queues)
	xasync_state.blocks = nil
	xasync_state.ports = nil
	xasync_state.queues = nil
	sync.mutex_unlock(&xasync_state.mu)

	_ = pq
	for p in ports_copy {
		sync.mutex_lock(&p.mu)
		p.closed = true
		p.terminated = true
		sync.cond_broadcast(&p.cond)
		ws := make([dynamic]^thread.Thread, 0, len(p.workers))
		for w in p.workers {
			append(&ws, w)
		}
		clear(&p.workers)
		sync.mutex_unlock(&p.mu)
		for w in ws {
			thread.join(w)
			thread.destroy(w)
		}
		delete(ws)
		delete(p.workers)
		delete(p.tasks)
		free(p)
	}
	delete(ports_copy)
	for q in queues_copy {
		delete(q.monitors)
		free(q)
	}
	delete(queues_copy)
}

@(private)
port_worker_proc :: proc(t: ^thread.Thread) {
	port := cast(^Task_Port)t.data
	for {
		sync.mutex_lock(&port.mu)
		for len(port.tasks) == 0 && !port.closed {
			sync.cond_wait(&port.cond, &port.mu)
		}
		if len(port.tasks) == 0 && port.closed {
			sync.mutex_unlock(&port.mu)
			return
		}
		task := port.tasks[0]
		ordered_remove(&port.tasks, 0)
		canceled := port.terminated
		sync.mutex_unlock(&port.mu)
		if task.callback != nil {
			task.callback(task.ctx, canceled)
		}
	}
}

@(private)
create_task_port :: proc(mode: Queue_Mode) -> ^Task_Port {
	init_xasync_if_needed()
	p := new(Task_Port)
	p.mode = mode
	p.refs = 1
	if mode == .Thread_Pool || mode == .Serialized {
		n := 1 if mode == .Serialized else 2
		for _ in 0 ..< n {
			w := thread.create(port_worker_proc)
			if w != nil {
				w.data = rawptr(p)
				append(&p.workers, w)
				thread.start(w)
			}
		}
	}
	sync.mutex_lock(&xasync_state.mu)
	append(&xasync_state.ports, p)
	sync.mutex_unlock(&xasync_state.mu)
	return p
}

@(private)
enqueue_on_port :: proc(p: ^Task_Port, q: ^Task_Queue, port_id: u32, cb: Task_Callback, ctx: rawptr) -> HRESULT {
	if p == nil {
		return E_INVALIDARG
	}
	sync.mutex_lock(&p.mu)
	if p.terminated {
		sync.mutex_unlock(&p.mu)
		return E_ABORT
	}
	mode := p.mode
	sync.mutex_unlock(&p.mu)

	if mode == .Immediate {
		if cb != nil {
			cb(ctx, false)
		}
		return S_OK
	}

	sync.mutex_lock(&p.mu)
	append(&p.tasks, Queued_Task{callback = cb, ctx = ctx})
	sync.cond_signal(&p.cond)
	sync.mutex_unlock(&p.mu)

	if q != nil {
		sync.mutex_lock(&q.mu)
		mons := make([dynamic]Monitor_Entry, len(q.monitors), context.temp_allocator)
		copy(mons[:], q.monitors[:])
		sync.mutex_unlock(&q.mu)
		for m in mons {
			if m.callback != nil {
				m.callback(m.ctx, q, port_id)
			}
		}
	}
	return S_OK
}

XTaskQueueCreate :: proc "system" (work_mode: u32, comp_mode: u32, out: ^^Task_Queue) -> HRESULT {
	context = hle_context()
	if out == nil || work_mode > u32(Queue_Mode.Immediate) || comp_mode > u32(Queue_Mode.Immediate) {
		return E_INVALIDARG
	}
	init_xasync_if_needed()
	q := new(Task_Queue)
	q.refs = 1
	q.work = create_task_port(Queue_Mode(work_mode))
	q.completion = create_task_port(Queue_Mode(comp_mode))
	sync.mutex_lock(&xasync_state.mu)
	append(&xasync_state.queues, q)
	sync.mutex_unlock(&xasync_state.mu)
	out^ = q
	return S_OK
}

XTaskQueueCreateComposite :: proc "system" (work_port: ^Task_Port, comp_port: ^Task_Port, out: ^^Task_Queue) -> HRESULT {
	context = hle_context()
	if out == nil || work_port == nil || comp_port == nil {
		return E_INVALIDARG
	}
	init_xasync_if_needed()
	q := new(Task_Queue)
	q.refs = 1
	q.work = work_port
	q.completion = comp_port
	sync.mutex_lock(&work_port.mu)
	work_port.refs += 1
	sync.mutex_unlock(&work_port.mu)
	sync.mutex_lock(&comp_port.mu)
	comp_port.refs += 1
	sync.mutex_unlock(&comp_port.mu)
	sync.mutex_lock(&xasync_state.mu)
	append(&xasync_state.queues, q)
	sync.mutex_unlock(&xasync_state.mu)
	out^ = q
	return S_OK
}

XTaskQueueGetPort :: proc "system" (q: ^Task_Queue, port_id: u32, out: ^^Task_Port) -> HRESULT {
	context = hle_context()
	if out == nil {
		return E_INVALIDARG
	}
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return E_INVALIDARG
	}
	switch port_id {
	case XASYNC_WORK_PORT:
		out^ = qq.work
		return S_OK
	case XASYNC_COMPLETION_PORT:
		out^ = qq.completion
		return S_OK
	}
	return E_INVALIDARG
}

XTaskQueueDuplicateHandle :: proc "system" (q: ^Task_Queue, out: ^^Task_Queue) -> HRESULT {
	context = hle_context()
	if out == nil {
		return E_INVALIDARG
	}
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return E_INVALIDARG
	}
	sync.mutex_lock(&qq.mu)
	qq.refs += 1
	sync.mutex_unlock(&qq.mu)
	out^ = qq
	return S_OK
}

XTaskQueueDispatch :: proc "system" (q: ^Task_Queue, port_id: u32, timeout_ms: u32) -> bool {
	context = hle_context()
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return false
	}
	p: ^Task_Port = nil
	if port_id == XASYNC_WORK_PORT {
		p = qq.work
	} else if port_id == XASYNC_COMPLETION_PORT {
		p = qq.completion
	} else {
		return false
	}
	sync.mutex_lock(&p.mu)
	if len(p.tasks) == 0 && timeout_ms != 0 {
		if timeout_ms == XASYNC_INFINITE {
			for len(p.tasks) == 0 && !p.closed {
				sync.cond_wait(&p.cond, &p.mu)
			}
		} else {
			_ = sync.cond_wait_with_timeout(&p.cond, &p.mu, time.Duration(timeout_ms) * time.Millisecond)
		}
	}
	if len(p.tasks) == 0 {
		sync.mutex_unlock(&p.mu)
		return false
	}
	task := p.tasks[0]
	ordered_remove(&p.tasks, 0)
	canceled := p.terminated
	sync.mutex_unlock(&p.mu)
	if task.callback != nil {
		task.callback(task.ctx, canceled)
	}
	return true
}

XTaskQueueCloseHandle :: proc "system" (q: ^Task_Queue) {
	context = hle_context()
	if q == nil {
		return
	}
	sync.mutex_lock(&q.mu)
	if q.refs > 0 {
		q.refs -= 1
	}
	sync.mutex_unlock(&q.mu)
}

XTaskQueueSubmitCallback :: proc "system" (q: ^Task_Queue, port_id: u32, ctx: rawptr, cb: Task_Callback) -> HRESULT {
	context = hle_context()
	if cb == nil {
		return E_INVALIDARG
	}
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return E_INVALIDARG
	}
	p: ^Task_Port
	if port_id == XASYNC_WORK_PORT {
		p = qq.work
	} else if port_id == XASYNC_COMPLETION_PORT {
		p = qq.completion
	} else {
		return E_INVALIDARG
	}
	return enqueue_on_port(p, qq, port_id, cb, ctx)
}

XTaskQueueSubmitDelayedCallback :: proc "system" (q: ^Task_Queue, port_id: u32, delay_ms: u32, ctx: rawptr, cb: Task_Callback) -> HRESULT {
	context = hle_context()
	if delay_ms == 0 {
		return XTaskQueueSubmitCallback(q, port_id, ctx, cb)
	}
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil || cb == nil {
		return E_INVALIDARG
	}
	Delayed_Args :: struct {
		q:        ^Task_Queue,
		port_id:  u32,
		delay_ms: u32,
		ctx:      rawptr,
		cb:       Task_Callback,
	}
	args := new(Delayed_Args)
	args^ = Delayed_Args{q = qq, port_id = port_id, delay_ms = delay_ms, ctx = ctx, cb = cb}
	worker := thread.create(proc(t: ^thread.Thread) {
		a := cast(^Delayed_Args)t.data
		time.sleep(time.Duration(a.delay_ms) * time.Millisecond)
		_ = XTaskQueueSubmitCallback(a.q, a.port_id, a.ctx, a.cb)
		free(a)
		thread.destroy(t)
	})
	if worker == nil {
		free(args)
		return E_OUTOFMEMORY
	}
	worker.data = rawptr(args)
	thread.start(worker)
	return S_OK
}

XTaskQueueTerminate :: proc "system" (q: ^Task_Queue, wait: bool, ctx: rawptr, cb: Terminated_Callback) -> HRESULT {
	context = hle_context()
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return E_INVALIDARG
	}
	sync.mutex_lock(&qq.mu)
	qq.terminated = true
	sync.mutex_unlock(&qq.mu)
	for p in ([2]^Task_Port{qq.work, qq.completion}) {
		if p != nil {
			sync.mutex_lock(&p.mu)
			p.terminated = true
			sync.cond_broadcast(&p.cond)
			sync.mutex_unlock(&p.mu)
		}
	}
	_ = wait
	if cb != nil {
		cb(ctx)
	}
	return S_OK
}

XTaskQueueRegisterMonitor :: proc "system" (q: ^Task_Queue, ctx: rawptr, cb: Monitor_Callback, out: ^u64) -> HRESULT {
	context = hle_context()
	if out == nil || cb == nil {
		return E_INVALIDARG
	}
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return E_INVALIDARG
	}
	tok := next_token()
	sync.mutex_lock(&qq.mu)
	append(&qq.monitors, Monitor_Entry{token = tok, ctx = ctx, callback = cb})
	sync.mutex_unlock(&qq.mu)
	out^ = tok
	return S_OK
}

XTaskQueueUnregisterMonitor :: proc "system" (q: ^Task_Queue, token: u64) {
	context = hle_context()
	qq := q if q != nil else get_process_queue_internal()
	if qq == nil {
		return
	}
	sync.mutex_lock(&qq.mu)
	defer sync.mutex_unlock(&qq.mu)
	for m, i in qq.monitors {
		if m.token == token {
			ordered_remove(&qq.monitors, i)
			break
		}
	}
}

@(private)
get_process_queue_internal :: proc() -> ^Task_Queue {
	init_xasync_if_needed()
	sync.mutex_lock(&xasync_state.mu)
	q := xasync_state.process_queue
	sync.mutex_unlock(&xasync_state.mu)
	if q != nil {
		return q
	}
	created: ^Task_Queue = nil
	_ = XTaskQueueCreate(u32(Queue_Mode.Thread_Pool), u32(Queue_Mode.Thread_Pool), &created)
	sync.mutex_lock(&xasync_state.mu)
	if xasync_state.process_queue == nil {
		xasync_state.process_queue = created
	} else {
		created = xasync_state.process_queue
	}
	sync.mutex_unlock(&xasync_state.mu)
	return created
}

XTaskQueueGetCurrentProcessTaskQueue :: proc "system" (out: ^^Task_Queue) -> bool {
	context = hle_context()
	if out == nil {
		return false
	}
	q := get_process_queue_internal()
	_ = XTaskQueueDuplicateHandle(q, out)
	return true
}

XTaskQueueSetCurrentProcessTaskQueue :: proc "system" (q: ^Task_Queue) {
	context = hle_context()
	init_xasync_if_needed()
	sync.mutex_lock(&xasync_state.mu)
	xasync_state.process_queue = q
	sync.mutex_unlock(&xasync_state.mu)
}

@(private)
get_or_create_async_entry :: proc(block: ^Async_Block, identity: rawptr, create_if_missing: bool) -> ^Async_Entry {
	init_xasync_if_needed()
	key := uintptr(block)
	sync.mutex_lock(&xasync_state.mu)
	defer sync.mutex_unlock(&xasync_state.mu)
	if e, ok := xasync_state.blocks[key]; ok {
		return e
	}
	if !create_if_missing {
		return nil
	}
	e := new(Async_Entry)
	e.id = xasync_state.next_id
	xasync_state.next_id += 1
	e.identity = identity
	e.status = E_PENDING
	xasync_state.blocks[key] = e
	return e
}

async_finished_with :: proc(block: ^Async_Block, identity: rawptr, hr: HRESULT, payload: []u8) -> HRESULT {
	if block == nil {
		return E_INVALIDARG
	}
	e := get_or_create_async_entry(block, identity, true)
	sync.mutex_lock(&xasync_state.mu)
	e.identity = identity
	if e.owns_mem && len(e.payload) > 0 {
		delete(e.payload)
	}
	if len(payload) > 0 {
		cp := make([]u8, len(payload))
		copy(cp, payload)
		e.payload = cp
		e.owns_mem = true
		e.result_size = len(cp)
	} else {
		e.payload = nil
		e.owns_mem = false
		e.result_size = 0
	}
	e.status = hr
	e.completed = true
	cb := block.callback
	q := block.queue
	sync.cond_broadcast(&xasync_state.cond)
	sync.mutex_unlock(&xasync_state.mu)

	if cb != nil {
		if q != nil {
			_ = XTaskQueueSubmitCallback(q, XASYNC_COMPLETION_PORT, rawptr(block), proc "system" (ctx: rawptr, _: bool) {
	context = hle_context()
				b := cast(^Async_Block)ctx
				if b != nil && b.callback != nil {
					b.callback(b)
				}
			})
		} else {
			cb(block)
		}
	}
	return S_OK
}

async_finished :: proc(block: ^Async_Block, identity: rawptr, hr: HRESULT) -> HRESULT {
	return async_finished_with(block, identity, hr, nil)
}

async_result_copy :: proc(block: ^Async_Block, identity: rawptr, out: ^$T) -> HRESULT {
	return XAsyncGetResult(block, identity, size_of(T), rawptr(out), nil)
}

async_bytes :: proc(v: ^$T) -> []u8 {
	return mem.byte_slice(v, size_of(T))
}

async_pending_with :: proc(block: ^Async_Block, identity: rawptr, fn: proc(user: rawptr) -> (HRESULT, []u8), user: rawptr = nil) -> HRESULT {
	if block == nil || fn == nil {
		return E_INVALIDARG
	}
	_ = get_or_create_async_entry(block, identity, true)
	Pending_Args :: struct {
		block:    ^Async_Block,
		identity: rawptr,
		fn:       proc(user: rawptr) -> (HRESULT, []u8),
		user:     rawptr,
	}
	args := new(Pending_Args)
	args^ = Pending_Args{block = block, identity = identity, fn = fn, user = user}
	t := thread.create(proc(th: ^thread.Thread) {
		a := cast(^Pending_Args)th.data
		hr, data := a.fn(a.user)
		_ = async_finished_with(a.block, a.identity, hr, data)
		if len(data) > 0 {
			delete(data)
		}
		free(a)
		thread.destroy(th)
	})
	if t == nil {
		free(args)
		return E_OUTOFMEMORY
	}
	t.data = rawptr(args)
	thread.start(t)
	return S_OK
}

XAsyncGetStatus :: proc "system" (block: ^Async_Block, wait: bool) -> HRESULT {
	context = hle_context()
	if block == nil {
		return E_INVALIDARG
	}
	init_xasync_if_needed()
	sync.mutex_lock(&xasync_state.mu)
	defer sync.mutex_unlock(&xasync_state.mu)
	e, ok := xasync_state.blocks[uintptr(block)]
	if !ok {
		return E_INVALIDARG
	}
	if wait {
		for !e.completed {
			sync.cond_wait(&xasync_state.cond, &xasync_state.mu)
		}
	}
	if !e.completed {
		return E_PENDING
	}
	return e.status
}

XAsyncGetResultSize :: proc "system" (block: ^Async_Block, out: ^uint) -> HRESULT {
	context = hle_context()
	if block == nil || out == nil {
		return E_INVALIDARG
	}
	init_xasync_if_needed()
	sync.mutex_lock(&xasync_state.mu)
	defer sync.mutex_unlock(&xasync_state.mu)
	e, ok := xasync_state.blocks[uintptr(block)]
	if !ok {
		return E_INVALIDARG
	}
	if !e.completed {
		return E_PENDING
	}
	if i32(e.status) < 0 {
		return e.status
	}
	out^ = e.result_size
	return S_OK
}

XAsyncGetResult :: proc "system" (
	block: ^Async_Block,
	identity: rawptr,
	buffer_size: uint,
	buffer: rawptr,
	buffer_used: ^uint,
) -> HRESULT {
	context = hle_context()
	if block == nil {
		return E_INVALIDARG
	}
	init_xasync_if_needed()
	sync.mutex_lock(&xasync_state.mu)
	defer sync.mutex_unlock(&xasync_state.mu)
	e, ok := xasync_state.blocks[uintptr(block)]
	if !ok || (identity != nil && e.identity != identity) {
		return E_INVALIDARG
	}
	if !e.completed {
		return E_PENDING
	}
	if i32(e.status) < 0 {
		return e.status
	}
	if e.result_size > 0 {
		if buffer == nil || buffer_size < e.result_size {
			return E_NOT_SUFFICIENT_BUFFER
		}
		if len(e.payload) >= int(e.result_size) {
			mem.copy(buffer, raw_data(e.payload), int(e.result_size))
		}
	}
	if buffer_used != nil {
		buffer_used^ = e.result_size
	}
	return S_OK
}

XAsyncComplete :: proc "system" (block: ^Async_Block, hr: HRESULT, result_size: uint) {
	context = hle_context()
	if block == nil {
		return
	}
	e := get_or_create_async_entry(block, nil, true)
	sync.mutex_lock(&xasync_state.mu)
	e.status = hr
	e.result_size = result_size
	e.completed = true
	cb := block.callback
	sync.cond_broadcast(&xasync_state.cond)
	sync.mutex_unlock(&xasync_state.mu)
	if cb != nil {
		cb(block)
	}
}

XAsyncCancel :: proc "system" (block: ^Async_Block) {
	context = hle_context()
	if block == nil {
		return
	}
	init_xasync_if_needed()
	sync.mutex_lock(&xasync_state.mu)
	if e, ok := xasync_state.blocks[uintptr(block)]; ok {
		e.canceled = true
		if !e.completed {
			e.status = E_ABORT
			e.completed = true
		}
		sync.cond_broadcast(&xasync_state.cond)
	}
	sync.mutex_unlock(&xasync_state.mu)
}

XAsyncRun :: proc "system" (block: ^Async_Block, work: Async_Work) -> HRESULT {
	context = hle_context()
	if block == nil || work == nil {
		return E_INVALIDARG
	}
	_ = get_or_create_async_entry(block, nil, true)
	hr := work(block)
	XAsyncComplete(block, hr, 0)
	return S_OK
}

XAsyncBegin :: proc "system" (
	block: ^Async_Block,
	ctx: rawptr,
	identity: rawptr,
	name: [^]u8,
	provider: Async_Provider,
) -> HRESULT {
	context = hle_context()
	_ = name
	if block == nil || provider == nil {
		return E_INVALIDARG
	}
	e := get_or_create_async_entry(block, identity, true)
	sync.mutex_lock(&xasync_state.mu)
	e.identity = identity
	sync.mutex_unlock(&xasync_state.mu)
	data := Provider_Data{block = block, context_ = ctx, identity = identity}
	hr := provider(XASYNC_OP_BEGIN, &data)
	sync.mutex_lock(&xasync_state.mu)
	if e.completed && i32(e.status) >= 0 && e.result_size > 0 && (!e.owns_mem || len(e.payload) == 0) {
		buf := make([]u8, e.result_size)
		get_data := Provider_Data{
			block       = block,
			context_    = ctx,
			identity    = identity,
			buffer_size = e.result_size,
			buffer      = raw_data(buf),
		}
		sync.mutex_unlock(&xasync_state.mu)
		_ = provider(XASYNC_OP_GET_RESULT, &get_data)
		sync.mutex_lock(&xasync_state.mu)
		e.payload = buf
		e.owns_mem = true
	}
	sync.mutex_unlock(&xasync_state.mu)
	return hr
}

XAsyncSchedule :: proc "system" (block: ^Async_Block, delay_ms: u32) -> HRESULT {
	context = hle_context()
	_ = delay_ms
	if block == nil {
		return E_INVALIDARG
	}
	return S_OK
}

// --- xasync COM vtable (31 slots) ---

@(private) m_async_get_status :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, wait: u8) -> HRESULT {
	context = hle_context()
	return XAsyncGetStatus(b, wait != 0)
}
@(private) m_async_get_result_size :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, out: ^uint) -> HRESULT {
	context = hle_context()
	return XAsyncGetResultSize(b, out)
}
@(private) m_async_cancel :: proc "system" (_: ^Runtime_Object, b: ^Async_Block) { context = hle_context(); XAsyncCancel(b) }
@(private) m_async_run :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, work: Async_Work) -> HRESULT {
	context = hle_context()
	return XAsyncRun(b, work)
}
@(private) m_async_begin :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, ctx, identity: rawptr, name: [^]u8, prov: Async_Provider) -> HRESULT {
	context = hle_context()
	return XAsyncBegin(b, ctx, identity, name, prov)
}
@(private) m_async_schedule :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, delay_ms: u32) -> HRESULT {
	context = hle_context()
	return XAsyncSchedule(b, delay_ms)
}
@(private) m_async_complete :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, hr: HRESULT, size: uint) {
	context = hle_context()
	XAsyncComplete(b, hr, size)
}
@(private) m_async_get_result :: proc "system" (_: ^Runtime_Object, b: ^Async_Block, id: rawptr, sz: uint, buf: rawptr, used: ^uint) -> HRESULT {
	context = hle_context()
	return XAsyncGetResult(b, id, sz, buf, used)
}
@(private) m_tq_create :: proc "system" (_: ^Runtime_Object, w, c: u32, out: ^^Task_Queue) -> HRESULT {
	context = hle_context()
	return XTaskQueueCreate(w, c, out)
}
@(private) m_tq_create_composite :: proc "system" (_: ^Runtime_Object, w, c: ^Task_Port, out: ^^Task_Queue) -> HRESULT {
	context = hle_context()
	return XTaskQueueCreateComposite(w, c, out)
}
@(private) m_tq_get_port :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, pid: u32, out: ^^Task_Port) -> HRESULT {
	context = hle_context()
	return XTaskQueueGetPort(q, pid, out)
}
@(private) m_tq_duplicate :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, out: ^^Task_Queue) -> HRESULT {
	context = hle_context()
	return XTaskQueueDuplicateHandle(q, out)
}
@(private) m_tq_dispatch :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, pid: u32, t: u32) -> bool {
	context = hle_context()
	return XTaskQueueDispatch(q, pid, t)
}
@(private) m_tq_close :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue) {
	context = hle_context()
	XTaskQueueCloseHandle(q)
}
@(private) m_tq_submit :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, pid: u32, ctx: rawptr, cb: Task_Callback) -> HRESULT {
	context = hle_context()
	return XTaskQueueSubmitCallback(q, pid, ctx, cb)
}
@(private) m_tq_submit_delayed :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, pid: u32, d: u32, ctx: rawptr, cb: Task_Callback) -> HRESULT {
	context = hle_context()
	return XTaskQueueSubmitDelayedCallback(q, pid, d, ctx, cb)
}
@(private) m_tq_terminate :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, wait: u8, ctx: rawptr, cb: Terminated_Callback) -> HRESULT {
	context = hle_context()
	return XTaskQueueTerminate(q, wait != 0, ctx, cb)
}
@(private) m_tq_reg_mon :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, ctx: rawptr, cb: Monitor_Callback, out: ^u64) -> HRESULT {
	context = hle_context()
	return XTaskQueueRegisterMonitor(q, ctx, cb, out)
}
@(private) m_tq_unreg_mon :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue, tok: u64) {
	context = hle_context()
	XTaskQueueUnregisterMonitor(q, tok)
}
@(private) m_tq_get_proc :: proc "system" (_: ^Runtime_Object, out: ^^Task_Queue) -> bool {
	context = hle_context()
	return XTaskQueueGetCurrentProcessTaskQueue(out)
}
@(private) m_tq_set_proc :: proc "system" (_: ^Runtime_Object, q: ^Task_Queue) {
	context = hle_context()
	XTaskQueueSetCurrentProcessTaskQueue(q)
}
@(private) m_tq_check_thread :: proc "system" (_: ^Runtime_Object) -> bool { context = hle_context(); return true }

XASYNC_VTABLE := [31]rawptr {
	rawptr(rt_missing),
	rawptr(rt_add_ref),
	rawptr(rt_add_ref),
	rawptr(m_async_get_status),      // 0x18
	rawptr(m_async_get_result_size), // 0x20
	rawptr(m_async_cancel),          // 0x28
	rawptr(m_async_run),             // 0x30
	rawptr(m_async_begin),           // 0x38
	rawptr(rt_missing),              // 0x40
	rawptr(m_async_schedule),        // 0x48
	rawptr(m_async_complete),        // 0x50
	rawptr(m_async_get_result),      // 0x58
	rawptr(m_tq_create),             // 0x60
	rawptr(m_tq_create_composite),   // 0x68
	rawptr(m_tq_get_port),           // 0x70
	rawptr(m_tq_duplicate),          // 0x78
	rawptr(m_tq_dispatch),           // 0x80
	rawptr(m_tq_close),              // 0x88
	rawptr(m_tq_submit),             // 0x90
	rawptr(m_tq_submit_delayed),     // 0x98
	rawptr(rt_missing),              // 0xa0
	rawptr(rt_missing),              // 0xa8
	rawptr(m_tq_terminate),          // 0xb0
	rawptr(m_tq_reg_mon),            // 0xb8
	rawptr(m_tq_unreg_mon),          // 0xc0
	rawptr(m_tq_get_proc),           // 0xc8
	rawptr(m_tq_set_proc),           // 0xd0
	rawptr(rt_missing),              // 0xd8
	rawptr(rt_missing),              // 0xe0
	rawptr(m_tq_check_thread),       // 0xe8
	rawptr(rt_missing),              // 0xf0
}

XASYNC_OBJECT := Runtime_Object{vtable = raw_data(XASYNC_VTABLE[:]), area = "task queue"}

// --- xgameruntime.dll exports ---

XGameRuntimeInitialize :: proc "system" () -> HRESULT { context = hle_context(); return S_OK }
XGameRuntimeUninitialize :: proc "system" () {}
InitializeApiImpl :: proc "system" (_version, _build: u64) -> HRESULT { context = hle_context(); return S_OK }
InitializeApiImplEx :: proc "system" (_version, _build, _flags: u64) -> HRESULT { context = hle_context(); return S_OK }
InitializeApiImplEx2 :: proc "system" (_version, _build, _flags: u64, _opts: rawptr) -> HRESULT { context = hle_context(); return S_OK }
UninitializeApiImpl :: proc "system" () {}
XErrorReport :: proc "system" (_hr: HRESULT, _message: cstring) {}

QueryApiImpl :: proc "system" (provider: ^Guid, iid: ^Guid, out: ^rawptr) -> HRESULT {
	context = hle_context()
	if provider == nil || iid == nil {
		return NOT_SUPPORTED
	}
	obj, ok := find_runtime_interface(provider^, iid^)
	if ok && out != nil {
		out^ = rawptr(obj)
		return S_OK
	}
	return NOT_SUPPORTED
}

XGAMERUNTIME_DLLS := [?]string{"xgameruntime.dll"}
XGAMERUNTIME_EXPORTS := [?]Hle_Export {
	{name = "XGameRuntimeInitialize", address = uintptr(rawptr(XGameRuntimeInitialize))},
	{name = "XGameRuntimeUninitialize", address = uintptr(rawptr(XGameRuntimeUninitialize))},
	{name = "InitializeApiImpl", address = uintptr(rawptr(InitializeApiImpl))},
	{name = "InitializeApiImplEx", address = uintptr(rawptr(InitializeApiImplEx))},
	{name = "InitializeApiImplEx2", address = uintptr(rawptr(InitializeApiImplEx2))},
	{name = "UninitializeApiImpl", address = uintptr(rawptr(UninitializeApiImpl))},
	{name = "QueryApiImpl", address = uintptr(rawptr(QueryApiImpl))},
	{name = "XErrorReport", address = uintptr(rawptr(XErrorReport))},
}
