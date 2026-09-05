#define _DARWIN_C_SOURCE
#include "include/loupe_fs.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/resource.h>
#include <sys/snapshot.h>
#include <sys/stat.h>
#include <sys/vnode.h>

void loupe_disable_dataless_materialization(void) {
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                   IOPOL_SCOPE_PROCESS,
                   IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
}

// MARK: - Batch directory reader

struct loupe_dir_reader {
    int      fd;
    int32_t  device;
    char    *buffer;
    size_t   buffer_size;
    char    *cursor;      // next undecoded entry inside the current batch
    char    *batch_end;   // one past the last byte the kernel wrote
    int      remaining;   // entries left in the current batch
    bool     measure_private_size;
};

/// The attribute request, built once per open.
///
/// Ordering is not a stylistic choice: the kernel packs attributes in ascending
/// bit order within each group, so the decoder below must read them back in
/// exactly this sequence. ATTR_CMN_RETURNED_ATTRS is the one exception — it is
/// hoisted to the front of every entry regardless of its bit value.
static void loupe_fill_request(struct attrlist *al, bool measure_private_size) {
    memset(al, 0, sizeof *al);
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID
                   | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS
                   | ATTR_CMN_FILEID | ATTR_CMN_ERROR;
    al->fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    // ATTR_CMNEXT_* extend the common attributes but travel in the fork group.
    // Measured: populated on APFS with options 0 — FSOPT_ATTR_CMN_EXTENDED is
    // not required, and is deliberately not passed because it also changes how
    // two common-attribute bits are interpreted.
    //
    // Requesting it costs 3.6x throughput (see the header), so it is opt-in.
    al->forkattr = measure_private_size ? ATTR_CMNEXT_PRIVATESIZE : 0;
}

loupe_dir_reader_t *loupe_dir_reader_create(void) {
    loupe_dir_reader_t *r = calloc(1, sizeof *r);
    if (r) { r->fd = -1; }
    return r;
}

void loupe_dir_reader_destroy(loupe_dir_reader_t *reader) {
    if (!reader) { return; }
    loupe_dir_reader_close(reader);
    free(reader);
}

int loupe_dir_reader_open(loupe_dir_reader_t *reader, const char *path,
                          void *buffer, size_t buffer_size,
                          bool measure_private_size) {
    if (!reader || !path || !buffer || buffer_size < 4096) { return EINVAL; }
    loupe_dir_reader_close(reader);

    // O_NOFOLLOW: a symlink to a directory must never be enumerated as one.
    // O_CLOEXEC: a scan holds fds on several threads; none of them belongs in
    // a child process if the app ever spawns one.
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { return errno; }

    struct stat st;
    if (fstat(fd, &st) != 0) { int e = errno; close(fd); return e; }

    reader->fd = fd;
    reader->device = (int32_t)st.st_dev;
    reader->buffer = buffer;
    reader->buffer_size = buffer_size;
    reader->cursor = buffer;
    reader->batch_end = buffer;
    reader->remaining = 0;
    reader->measure_private_size = measure_private_size;
    return 0;
}

int loupe_dir_reader_fd(const loupe_dir_reader_t *reader) {
    return reader ? reader->fd : -1;
}

int32_t loupe_dir_reader_device(const loupe_dir_reader_t *reader) {
    return reader ? reader->device : 0;
}

void loupe_dir_reader_close(loupe_dir_reader_t *reader) {
    if (!reader) { return; }
    if (reader->fd >= 0) { close(reader->fd); reader->fd = -1; }
    reader->buffer = NULL;
    reader->buffer_size = 0;
    reader->cursor = NULL;
    reader->batch_end = NULL;
    reader->remaining = 0;
}

/// Reads the next batch into the caller's buffer.
/// - Returns: entries read (0 at end of directory) or `-errno`.
static int loupe_dir_reader_refill(loupe_dir_reader_t *reader) {
    struct attrlist al;
    loupe_fill_request(&al, reader->measure_private_size);
    errno = 0;
    int count = getattrlistbulk(reader->fd, &al, reader->buffer,
                                reader->buffer_size, 0);
    if (count < 0) { return -errno; }
    reader->cursor = reader->buffer;
    // The kernel reports how many entries it packed, not how many bytes. The
    // per-entry length prefixes walk the buffer; the buffer end is the only
    // hard bound we have, so it is what the decoder checks against.
    reader->batch_end = reader->buffer + reader->buffer_size;
    reader->remaining = count;
    return count;
}

int loupe_dir_reader_next(loupe_dir_reader_t *reader, loupe_entry_t *out) {
    if (!reader || !out || reader->fd < 0) { return -EINVAL; }

    for (;;) {
        if (reader->remaining == 0) {
            int refilled = loupe_dir_reader_refill(reader);
            if (refilled < 0) { return refilled; }
            if (refilled == 0) { return LOUPE_END; }
        }

        char *entry = reader->cursor;
        // Minimum viable entry: the length prefix plus the returned-attrs mask.
        if ((size_t)(reader->batch_end - entry) < sizeof(uint32_t) + sizeof(attribute_set_t)) {
            return -EIO;
        }

        uint32_t entry_length;
        memcpy(&entry_length, entry, sizeof entry_length);
        if (entry_length < sizeof(uint32_t) + sizeof(attribute_set_t)
            || (size_t)(reader->batch_end - entry) < entry_length) {
            // A malformed length would desynchronise every remaining entry in
            // the buffer, so stop rather than decode garbage.
            return -EIO;
        }

        reader->cursor = entry + entry_length;
        reader->remaining -= 1;

        char *field = entry + sizeof(uint32_t);
        attribute_set_t returned;
        memcpy(&returned, field, sizeof returned);
        field += sizeof returned;

        char *const entry_end = entry + entry_length;
        // Every read below is guarded by this: the returned-attrs mask says an
        // attribute is present, but the entry's own length is what proves the
        // bytes are really there.
        #define LOUPE_TAKE(dst, size)                                   \
            do {                                                        \
                if ((size_t)(entry_end - field) < (size_t)(size)) { return -EIO; } \
                memcpy((dst), field, (size));                           \
                field += (size);                                        \
            } while (0)

        memset(out, 0, sizeof *out);

        // --- common group, ascending bit order ------------------------------
        if (returned.commonattr & ATTR_CMN_NAME) {
            attrreference_t ref;
            char *ref_at = field;
            LOUPE_TAKE(&ref, sizeof ref);
            char *name = ref_at + ref.attr_dataoffset;
            if (name < entry || name >= entry_end) { return -EIO; }
            // attr_length counts the NUL; strnlen re-derives the length so a
            // surprising attr_length cannot walk Swift off the end of the name.
            size_t max = (size_t)(entry_end - name);
            out->name = name;
            out->name_len = (uint32_t)strnlen(name, max);
        }
        if (returned.commonattr & ATTR_CMN_DEVID) {
            dev_t dev = 0;
            LOUPE_TAKE(&dev, sizeof dev);
            out->dev_id = (int32_t)dev;
        }
        if (returned.commonattr & ATTR_CMN_OBJTYPE) {
            fsobj_type_t type = 0;
            LOUPE_TAKE(&type, sizeof type);
            out->obj_type = (uint32_t)type;
        }
        if (returned.commonattr & ATTR_CMN_MODTIME) {
            struct timespec ts;
            LOUPE_TAKE(&ts, sizeof ts);
            // Seconds only: the arena stores mtime as UInt32 and nothing in the
            // product reasons about sub-second file ages.
            out->mtime_sec = (uint32_t)ts.tv_sec;
        }
        if (returned.commonattr & ATTR_CMN_FLAGS) {
            LOUPE_TAKE(&out->cmn_flags, sizeof out->cmn_flags);
        }
        if (returned.commonattr & ATTR_CMN_FILEID) {
            LOUPE_TAKE(&out->file_id, sizeof out->file_id);
        }
        if (returned.commonattr & ATTR_CMN_ERROR) {
            LOUPE_TAKE(&out->entry_error, sizeof out->entry_error);
        }

        // --- file group -----------------------------------------------------
        // Absent for directories, and absent again for any entry the kernel
        // failed on. Consuming these bytes unconditionally is the mistake that
        // desynchronises the whole buffer; the mask is the only safe guide.
        if (returned.fileattr & ATTR_FILE_LINKCOUNT) {
            LOUPE_TAKE(&out->link_count, sizeof out->link_count);
        }
        if (returned.fileattr & ATTR_FILE_TOTALSIZE) {
            LOUPE_TAKE(&out->logical_size, sizeof out->logical_size);
        }
        if (returned.fileattr & ATTR_FILE_ALLOCSIZE) {
            LOUPE_TAKE(&out->alloc_size, sizeof out->alloc_size);
        }

        // --- fork group (ATTR_CMNEXT_*) -------------------------------------
        if (returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) {
            LOUPE_TAKE(&out->private_size, sizeof out->private_size);
        }

        #undef LOUPE_TAKE

        // getattrlistbulk is documented not to return "." or "..", but a single
        // unfiltered "." would make the walker descend into the directory it is
        // already reading, forever. Dropping them is decode hygiene, not policy.
        if (out->name != NULL
            && (strcmp(out->name, ".") == 0 || strcmp(out->name, "..") == 0)) {
            continue;
        }

        return LOUPE_ENTRY;
    }
}

// MARK: - Snapshots

int loupe_list_snapshots(const char *mount_point, void *scratch, size_t scratch_size,
                         char *out_names, size_t out_names_size) {
    if (!mount_point || !scratch || !out_names || scratch_size < 4096
        || out_names_size == 0) {
        return -EINVAL;
    }

    int fd = open(mount_point, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { return -errno; }

    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_BULK_REQUIRED;   // RETURNED_ATTRS | NAME

    int total = 0;
    size_t written = 0;
    int count;
    while ((count = fs_snapshot_list(fd, &al, scratch, scratch_size, 0)) > 0) {
        char *entry = (char *)scratch;
        char *const buffer_end = (char *)scratch + scratch_size;
        for (int i = 0; i < count; i++) {
            if ((size_t)(buffer_end - entry) < sizeof(uint32_t) + sizeof(attribute_set_t)) {
                close(fd); return -EIO;
            }
            uint32_t entry_length;
            memcpy(&entry_length, entry, sizeof entry_length);
            if (entry_length < sizeof(uint32_t) + sizeof(attribute_set_t)
                || (size_t)(buffer_end - entry) < entry_length) {
                close(fd); return -EIO;
            }
            char *field = entry + sizeof(uint32_t);
            attribute_set_t returned;
            memcpy(&returned, field, sizeof returned);
            field += sizeof returned;

            if (returned.commonattr & ATTR_CMN_NAME) {
                attrreference_t ref;
                char *ref_at = field;
                memcpy(&ref, field, sizeof ref);
                char *name = ref_at + ref.attr_dataoffset;
                if (name < entry || name >= entry + entry_length) { close(fd); return -EIO; }
                size_t len = strnlen(name, (size_t)(entry + entry_length - name));
                if (written + len + 1 > out_names_size) { close(fd); return -ERANGE; }
                memcpy(out_names + written, name, len);
                written += len;
                out_names[written++] = '\0';
                total++;
            }
            entry += entry_length;
        }
    }
    if (count < 0) { int e = errno; close(fd); return -e; }
    close(fd);
    return total;
}
