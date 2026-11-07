//! Platform-neutral clipboard values. Text, HTML fragments and file paths are UTF-8.
//! Writes borrow their input. Reads own every slice (including the file-list slice)
//! using the supplied allocator; release them with the platform clipboard.free.

/// Tightly packed, top-to-bottom, straight (not premultiplied) RGBA8 pixels.
/// Dimensions must be nonzero and rgba.len must equal width * height * 4.
pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
};

pub const Format = enum { text, html, image, files };

pub const Data = union(Format) {
    text: []const u8,
    /// An HTML fragment, not the Windows CF_HTML transport header.
    html: []const u8,
    image: Image,
    files: []const []const u8,
};

// Run Windows codec tests from this module so relative imports stay inside the
// module root. No test opens or changes the system clipboard.
test {
    if (@import("builtin").os.tag == .windows) {
        _ = @import("platform/windows/clipboard.zig");
    }
}
