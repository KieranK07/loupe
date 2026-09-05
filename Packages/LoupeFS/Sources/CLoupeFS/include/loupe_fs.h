#ifndef LOUPE_FS_H
#define LOUPE_FS_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/// One decoded directory entry. Mirrors exactly the attributes Loupe requests
/// from getattrlistbulk, flattened so Swift never touches the packed,
/// variable-layout attribute buffer the kernel returns.
typedef struct {
    const char *name;      // borrowed, valid until the next batch read
    uint32_t    name_len;
    uint64_t    file_id;   // inode
    int32_t     dev_id;    // device boundary enforcement
    uint32_t    obj_type;  // VREG / VDIR / VLNK ...
    uint32_t    cmn_flags; // SF_DATALESS | SF_FIRMLINK | SF_RESTRICTED | UF_COMPRESSED
    uint32_t    link_count;
    uint64_t    logical_size;   // ATTR_FILE_TOTALSIZE
    uint64_t    alloc_size;     // ATTR_FILE_ALLOCSIZE (always a 4KiB multiple)
    uint64_t    private_size;   // ATTR_CMNEXT_PRIVATESIZE, 0 unless requested
    uint32_t    entry_error;    // per-entry errno from ATTR_CMN_ERROR, 0 if fine
    uint32_t    mtime_sec;
} loupe_entry_t;

/// Values of `loupe_entry_t.obj_type`, mirroring `enum vtype` in <sys/vnode.h>.
/// Redeclared here so Swift gets plain integers rather than an imported C enum.
#define LOUPE_OBJ_REG 1
#define LOUPE_OBJ_DIR 2
#define LOUPE_OBJ_LNK 5

/// Bits of `loupe_entry_t.cmn_flags` Loupe acts on. Values are from <sys/stat.h>
/// and are restated here so the Swift side never has to guess which of several
/// similarly-named Darwin constants the walker meant.
#define LOUPE_UF_COMPRESSED  0x00000020u
#define LOUPE_SF_RESTRICTED  0x00080000u
#define LOUPE_SF_FIRMLINK    0x00800000u
#define LOUPE_SF_DATALESS    0x40000000u

/// Disable iCloud dataless-file materialisation for the calling process.
///
/// THIS IS NOT OPTIONAL. A scan of a normal home directory touches six figures
/// of dataless placeholders (132,390 measured on the development machine).
/// Without this call the walk downloads the user's entire iCloud Drive.
/// Must be called once before any walking begins.
void loupe_disable_dataless_materialization(void);

// MARK: - Batch directory reader

/// A batch reader over one directory.
///
/// Opaque because its only interesting field is a cursor into a packed,
/// variable-layout attribute buffer, and that layout is precisely what this
/// shim exists to keep out of Swift. One reader plus one buffer is allocated
/// per walker thread and reused for every directory that thread visits.
///
/// This type decodes; it does not decide. It reports firmlinks, device ids,
/// dataless flags and per-entry errors verbatim and takes no action on any of
/// them — every policy question ("descend?", "count the bytes?") belongs to
/// the Swift caller.
typedef struct loupe_dir_reader loupe_dir_reader_t;

/// Return values of `loupe_dir_reader_next`. Anything negative is `-errno`.
#define LOUPE_END   0
#define LOUPE_ENTRY 1

loupe_dir_reader_t *loupe_dir_reader_create(void);
void loupe_dir_reader_destroy(loupe_dir_reader_t *reader);

/// Opens `path` for enumeration into the caller's `buffer`, which must stay
/// valid and untouched until the reader is closed. 256 KiB is the size the
/// prototypes measured; smaller buffers cost extra syscalls on large directories.
///
/// The directory is opened `O_NOFOLLOW`, so a symlink pointing at a directory
/// is never enumerated through — that is what stops a symlink cycle from
/// becoming a walk cycle.
///
/// `measure_private_size` adds `ATTR_CMNEXT_PRIVATESIZE` to the request. It
/// works and its answers are correct, but it is NOT free: measured on this
/// machine, asking for it drops a `/Applications` walk from 905,000 to 245,000
/// entries/sec — a 3.6x tax, paid in the kernel, for a number Loupe uses only
/// to tell an APFS clone from an ordinary file. It is off by default and the
/// Swift caller decides.
///
/// - Returns: 0 on success, otherwise a positive `errno`.
int loupe_dir_reader_open(loupe_dir_reader_t *reader, const char *path,
                          void *buffer, size_t buffer_size,
                          bool measure_private_size);

/// Decodes the next entry.
///
/// - Returns: `LOUPE_ENTRY` with `out` filled, `LOUPE_END` at the end of the
///   directory, or `-errno` on failure. `out->name` points into the caller's
///   buffer and is invalidated by the next call.
int loupe_dir_reader_next(loupe_dir_reader_t *reader, loupe_entry_t *out);

/// The open directory descriptor, for `faccessat`-style questions about a child
/// that would otherwise need a second full path resolution.
int loupe_dir_reader_fd(const loupe_dir_reader_t *reader);

/// `st_dev` of the directory itself, taken by `fstat` at open time. The walker
/// compares this against each entry's `dev_id` to enforce the device boundary.
int32_t loupe_dir_reader_device(const loupe_dir_reader_t *reader);

void loupe_dir_reader_close(loupe_dir_reader_t *reader);

// MARK: - Snapshots

/// Lists local APFS snapshot names on the volume mounted at `mount_point`.
///
/// Wraps `fs_snapshot_list(2)`, which needs no privilege and cannot raise an
/// authorization prompt — see the note at the top of `SnapshotReader.swift`
/// for why that property is non-negotiable here.
///
/// Names are written into `out_names` as consecutive NUL-terminated strings.
///
/// - Returns: the number of snapshots written, or `-errno`. If the buffer is
///   too small the call fails with `-ERANGE` rather than truncating.
int loupe_list_snapshots(const char *mount_point, void *scratch, size_t scratch_size,
                         char *out_names, size_t out_names_size);

#endif
