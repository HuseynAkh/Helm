<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

K20 / M18 tag adapters

Use a shared XattrTagStorage through Core's TagStorage seam. TagBulkApplier accepts
file URLs and returns Core's ordered TagEditResult, retaining partial failures and
deduplicating local ItemIDs. Helm-private stars remain independent (F-029); the old
app has no Finder tag implementation to port. No global tag catalogue is changed.

Darwin uses com.apple.metadata:_kMDItemUserTags. Linux uses the required user.
namespace prefix; Linux fixtures are interoperability tests, not Finder metadata.
The Glibc Swift module omits xattr declarations; the tiny native bridge declares
libc symbols with Linux C ABI signatures, without a new manifest/C target.
Native calls follow symlinks. Only the tag attribute is changed; contents and other
attributes are untouched. Invalid plists are rejected without replacement.

Edits are serialized across XattrTagStorage instances in this process. Each edit
reads, decodes, compares a fresh read, and retries three times on change. There is
no kernel compare-and-swap; other processes can still race between comparison and
write, and path replacement can redirect an operation. This is explicitly best
effort, not transactional storage. I/O is synchronous within the actor; composition
with the filesystem executor for stalled network providers remains future work.

ResourceValuesTagStorage is macOS-only and presents names through tagNamesKey.
Deviation: writes delegate to the lossless xattr adapter rather than setting
URLResourceValues.tagNames, which cannot preserve unknown color suffixes. This
means resource values do not provide a write fallback on unsupported filesystems.
CompositeTagStorage defaults to xattrs only; inject a resource-values fallback
explicitly for name-only reads. Only unsupported errors select the fallback;
permission, missing-file, malformed-data and conflict failures propagate.

MAC-VERIFY: compile Darwin signatures and Foundation keys/error constants with
Xcode/macOS 14, then compare tags/colors with Finder on an approved fixture.
Opus must review the Linux C bridge, comparison limits and resource-values write
policy after 22:00 Toronto on 2026-11-04. Needed changes elsewhere: none required
for compilation; a Core richer tag error contract and executor integration may be
useful later but were not added outside lane ownership.

Linux tests cover temporary-directory and /dev/shm xattrs (skip only unsupported
filesystems), unchanged contents/other attributes, unknown suffixes, removal,
missing files, fake errno mapping, concurrent-change retries/conflicts, malformed
plists, partial failures and fallback selection. K20 fixtures are intentionally
retained in temporary locations to respect the session's no-deletion instruction.
