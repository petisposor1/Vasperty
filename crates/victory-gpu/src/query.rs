//! Query heaps backed by real host `ID3D12QueryHeap` objects when a host GPU
//! is present, supporting occlusion, binary occlusion, timestamp, pipeline
//! statistics, and stream-output queries.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use crate::object::{self, E_INVALIDARG, HRESULT, Iid, Object, QUERY_HEAP, Table, This, guid};
use crate::resource::PAGEABLE_IIDS;

#[cfg(windows)]
use windows::Win32::Graphics::Direct3D12::*;

const HEAP_IIDS: [Iid; 4] = [
    guid(
        0x0d9658ae,
        0xed45,
        0x469e,
        [0xa6, 0x1d, 0x97, 0x0e, 0xc5, 0x83, 0xca, 0xb4],
    ),
    PAGEABLE_IIDS[0],
    PAGEABLE_IIDS[1],
    PAGEABLE_IIDS[2],
];

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) struct Desc {
    pub(crate) kind: u32,
    pub(crate) count: u32,
    nodes: u32,
}

#[repr(C)]
struct Heap {
    object: Object,
    desc: Desc,
    #[cfg(windows)]
    host: Option<ID3D12QueryHeap>,
}

/// Maps a console query heap kind to a host D3D12 query heap type.
/// Copy-queue timestamps (5) map to regular timestamps because VIctory
/// executes all lists on its direct queue.
#[cfg(windows)]
fn host_heap_type(kind: u32) -> Option<D3D12_QUERY_HEAP_TYPE> {
    Some(match kind {
        0 => D3D12_QUERY_HEAP_TYPE_OCCLUSION,
        1 | 5 => D3D12_QUERY_HEAP_TYPE_TIMESTAMP,
        2 => D3D12_QUERY_HEAP_TYPE_PIPELINE_STATISTICS,
        3 => D3D12_QUERY_HEAP_TYPE_SO_STATISTICS,
        _ => return None,
    })
}

/// Maps a console query type to a host D3D12 query type, checking that it is
/// compatible with the heap's `heap_kind`.
#[cfg(windows)]
pub(crate) fn host_query_type(heap_kind: u32, query_kind: u32) -> Option<D3D12_QUERY_TYPE> {
    match (heap_kind, query_kind) {
        (0, 0) => Some(D3D12_QUERY_TYPE_OCCLUSION),
        (0, 1) => Some(D3D12_QUERY_TYPE_BINARY_OCCLUSION),
        (1 | 5, 2) => Some(D3D12_QUERY_TYPE_TIMESTAMP),
        (2, 3) => Some(D3D12_QUERY_TYPE_PIPELINE_STATISTICS),
        (3, 4) => Some(D3D12_QUERY_TYPE_SO_STATISTICS_STREAM0),
        (3, 5) => Some(D3D12_QUERY_TYPE_SO_STATISTICS_STREAM1),
        (3, 6) => Some(D3D12_QUERY_TYPE_SO_STATISTICS_STREAM2),
        (3, 7) => Some(D3D12_QUERY_TYPE_SO_STATISTICS_STREAM3),
        _ => None,
    }
}

/// Size in bytes of one resolved query result for `query_kind`.
pub(crate) fn result_size(query_kind: u32) -> u64 {
    match query_kind {
        0..=2 => 8,
        3 => 88,
        _ => 16,
    }
}

/// Returns the host query heap, console heap kind, and query count if backed
/// by a host D3D12 query heap.
#[cfg(windows)]
pub(crate) fn host_heap(this: This) -> Option<(ID3D12QueryHeap, u32, u32)> {
    if this.is_null() {
        return None;
    }
    // SAFETY: `this` is a live query heap created by `create`.
    let heap = unsafe { &*this.cast::<Heap>() };
    Some((heap.host.as_ref()?.clone(), heap.desc.kind, heap.desc.count))
}

/// Device method.
pub(crate) extern "system" fn create(
    _: This,
    desc: *const Desc,
    iid: *const Iid,
    out: *mut This,
) -> HRESULT {
    // SAFETY: the title passes a description (null is tolerated).
    let Some(&desc) = (unsafe { desc.as_ref() }) else {
        return E_INVALIDARG;
    };
    tracing::debug!(?desc, "query heap");
    #[cfg(windows)]
    let host = if !out.is_null() && desc.count > 0 {
        crate::host::host().and_then(|h| {
            let ty = host_heap_type(desc.kind)?;
            let host_desc = D3D12_QUERY_HEAP_DESC {
                Type: ty,
                Count: desc.count,
                NodeMask: 0,
            };
            let mut heap: Option<ID3D12QueryHeap> = None;
            // SAFETY: valid description on live device.
            let ok = unsafe { h.device.CreateQueryHeap(&host_desc, &mut heap) };
            match ok {
                Ok(()) => heap,
                Err(e) => {
                    tracing::warn!(error = %e, ?desc, "host query heap refused");
                    None
                }
            }
        })
    } else {
        None
    };
    let heap = Box::new(Heap {
        object: Object::new(&FUNCTIONS),
        desc,
        #[cfg(windows)]
        host,
    });
    object::hand_out(QUERY_HEAP, heap, iid, &HEAP_IIDS, out)
}

extern "system" fn query(this: This, iid: *const Iid, out: *mut This) -> HRESULT {
    object::answer(
        QUERY_HEAP,
        iid,
        object::is(iid, &HEAP_IIDS).then_some(this),
        out,
    )
}
extern "system" fn release(this: This) -> u32 {
    object::release_boxed::<Heap>(this)
}

/// IUnknown 3, object 4, device child 1.
static FUNCTIONS: Table<24> = {
    let mut f = object::d3d12_object(object::missing_table::<QUERY_HEAP, 24>());
    f[0] = query as *const ();
    f[2] = release as *const ();
    f[7] = object::parent_device as *const (); // 0x38
    Table(f)
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::object::{E_NOINTERFACE, E_POINTER, S_FALSE, S_OK, slot};

    #[test]
    fn null_descriptions_are_rejected() {
        let mut heap = std::ptr::null();
        assert_eq!(
            create(std::ptr::null(), std::ptr::null(), &HEAP_IIDS[0], &mut heap),
            E_INVALIDARG
        );
        assert!(heap.is_null());
        // The description is checked first: a probe with no room for the
        // heap fails on it rather than answering S_FALSE.
        assert_eq!(
            create(
                std::ptr::null(),
                std::ptr::null(),
                &HEAP_IIDS[0],
                std::ptr::null_mut()
            ),
            E_INVALIDARG
        );
    }

    #[test]
    fn creation_without_an_out_pointer_only_probes() {
        let desc = Desc {
            kind: 1, // timestamps
            count: 64,
            nodes: 0,
        };
        // A known interface with no out pointer asks whether creation would
        // succeed; the heap is dropped instead of handed out.
        assert_eq!(
            create(std::ptr::null(), &desc, &HEAP_IIDS[0], std::ptr::null_mut()),
            S_FALSE
        );
        // A null interface id is tolerated: no interface, no heap.
        let mut heap = std::ptr::null();
        assert_eq!(
            create(std::ptr::null(), &desc, std::ptr::null(), &mut heap),
            E_NOINTERFACE
        );
        assert!(heap.is_null());
    }

    #[test]
    fn heaps_answer_their_interfaces_and_count_references() {
        let desc = Desc {
            kind: 0, // occlusion
            count: 8,
            nodes: 0,
        };
        let null = std::ptr::null();
        let mut heap = null;
        assert_eq!(create(null, &desc, &HEAP_IIDS[0], &mut heap), S_OK);
        assert!(!heap.is_null());
        let query = slot::<extern "system" fn(This, *const Iid, *mut This) -> HRESULT>(heap, 0x0);
        // Every interface the heap answers to hands out the same object.
        for iid in &HEAP_IIDS {
            let mut out = null;
            assert_eq!(query(heap, iid, &mut out), S_OK);
            assert_eq!(out as usize, heap as usize);
        }
        // An unknown interface writes null behind and reports it missing.
        let unknown = [0u8; 16];
        let mut out = heap;
        assert_eq!(query(heap, &unknown, &mut out), E_NOINTERFACE);
        assert!(out.is_null());
        // A null interface id is tolerated rather than matched.
        let mut out = heap;
        assert_eq!(query(heap, std::ptr::null(), &mut out), E_NOINTERFACE);
        assert!(out.is_null());
        // No room for the answer is a pointer error.
        assert_eq!(query(heap, &unknown, std::ptr::null_mut()), E_POINTER);
        // References: one from creation, four from the queries, one added;
        // each release hands back what is left, the last frees the heap.
        assert_eq!(slot::<extern "system" fn(This) -> u32>(heap, 0x8)(heap), 6);
        let release = slot::<extern "system" fn(This) -> u32>(heap, 0x10);
        for left in [5, 4, 3, 2, 1, 0] {
            assert_eq!(release(heap), left);
        }
    }

    #[test]
    fn result_sizes_match_d3d12_query_types() {
        assert_eq!(result_size(0), 8); // occlusion
        assert_eq!(result_size(1), 8); // binary occlusion
        assert_eq!(result_size(2), 8); // timestamp
        assert_eq!(result_size(3), 88); // pipeline statistics
        assert_eq!(result_size(4), 16); // stream output statistics
    }

    #[cfg(windows)]
    #[test]
    fn host_query_heap_resolves_real_gpu_timestamps() {
        let Some(host) = crate::host::host() else {
            return;
        };
        let desc = Desc {
            kind: 1, // timestamp
            count: 4,
            nodes: 0,
        };
        let mut heap = std::ptr::null();
        assert_eq!(create(std::ptr::null(), &desc, &HEAP_IIDS[0], &mut heap), S_OK);
        let (host_heap, heap_kind, count) = host_heap(heap).expect("host query heap");
        assert_eq!((heap_kind, count), (1, 4));
        let (readback, mapped) = host.readback_buffer(16).expect("readback buffer");
        let list = host.new_list().expect("host list");
        // SAFETY: open list, live heap and readback buffer.
        unsafe {
            list.list
                .EndQuery(&host_heap, D3D12_QUERY_TYPE_TIMESTAMP, 0);
            list.list
                .EndQuery(&host_heap, D3D12_QUERY_TYPE_TIMESTAMP, 1);
            list.list.ResolveQueryData(
                &host_heap,
                D3D12_QUERY_TYPE_TIMESTAMP,
                0,
                2,
                &readback,
                0,
            );
        }
        list.close();
        host.execute(&[&list]);
        // SAFETY: two resolved u64 timestamps in the mapped readback buffer.
        let stamps = unsafe { std::slice::from_raw_parts(mapped.cast::<u64>(), 2) };
        assert!(stamps[1] >= stamps[0], "timestamps must be monotonic: {stamps:?}");
        assert_eq!(slot::<extern "system" fn(This) -> u32>(heap, 0x10)(heap), 0);
    }
}
