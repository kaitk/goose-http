// Serving files: is_safe_path, file_path, content_type_of, open_file, and
// serve_file with send_file, whole and as a range. Writes a file into the
// working directory, and deletes it.
import std;
import http from "../../";
import check from "../";

fn main() {
    assert(http::is_safe_path("a/b.txt") && http::is_safe_path("a..b/.c") && http::is_safe_path("x"));
    for p in ["../a", "a/..", "a/./b", ".", "a\\b", "c:x"] { assert(!http::is_safe_path(p)); }
    // file_path joins a directory and a decoded path that stays in it, and
    // leaves out as it was otherwise, escaped separators and dots included.
    let outside = ["..", "a/../b", "a/%2e%2E/b", "a%2F..%2Fb", "%00", "a%zz", "c%3Ax", "a%5Cb"];
    var path: u8[>..] = [];
    assert(http::file_path("www", "a%20b/c.txt", path) && path == "www/a b/c.txt");
    path.clear();
    assert(http::file_path("www/", "x", path) && path == "www/x");
    path.clear();
    assert(http::file_path("", "x", path) && path == "x");
    for e in outside {
        assert(!http::file_path("www", e, path) && path == "x");
    }
    // In the working directory, a path from '/' would be absolute.
    let rooted = ["/etc/x", "%2Fetc%2Fx", "//host/x"];
    for e in rooted {
        assert(!http::file_path("", e, path) && path == "x");
    }
    print("paths: ", outside.len + rooted.len, " outside the directory refused");
    assert(http::content_type_of("a/b.HTML") == "text/html; charset=utf-8");
    assert(http::content_type_of("x.tar.gz") == "application/gzip");
    assert(http::content_type_of("app.js.map") == "application/json");
    assert(http::content_type_of("site.webmanifest") == "application/manifest+json");
    assert(http::content_type_of("a.otf") == "font/otf");
    assert(http::content_type_of("README") == "application/octet-stream");
    assert(http::content_type_of("a.d/README") == "application/octet-stream");
    let none, missing = http::open_file("no such file here");
    assert(missing == 404 && none.fd < 0);
    print("content types; a missing file: ", missing);

    // A file larger than a piece, whole and as a range.
    var data: u8[>..] = [];
    for i in 200000 { data.push((i % 251) as! u8); }
    let name = "test_files.tmp";
    assert(write_file(name, data));
    for ranged in [false, true] {
        let f, s = http::open_file(name);
        assert(s == 200 && f.size == data.len);
        var rb: u8[>..] = [];
        let req = check::request("GET", if ranged { "Range: bytes=70000-70009\r\n" } else { "" }, rb);
        var out: u8[>..] = [];
        var keep = true;
        var st = http::Stream { .. };
        var body = http::FileBody { .. };
        let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: 1, head: false, stream: st };
        http::serve_file(req, reply, f, "a/b", body);
        var more = 0;
        while http::send_file(reply, body) { more++; }
        http::end(reply);
        assert(body.fd == -1 && keep);
        if ranged {
            assert(more == 0 && ends_with(out, data[70000..70010]));
            assert(find(out, "206 Partial Content") >= 0);
            assert(find(out, "Content-Range: bytes 70000-70009/200000\r\n") >= 0);
            print("a range of ", f.size, " bytes: 206");
        } else {
            assert(more == 3 && ends_with(out, data));
            assert(find(out, "Content-Length: 200000\r\n") >= 0);
            print("whole, ", f.size, " bytes: ", more, " more pieces");
        }
        assert(find(out, str("ETag: ", http::file_tag(f), "\r\n")) >= 0);
    }
    // file_tag is the tag serve_file sends, so a program's own 304 matches
    // serve_file's.
    let f, s = http::open_file(name);
    assert(s == 200);
    let tag = http::file_tag(f);
    assert(tag[0] == '"' && tag[tag.len - 1] == '"');
    var rb: u8[>..] = [];
    let req = check::request("GET", str("If-None-Match: ", tag, "\r\n"), rb);
    assert(http::not_modified(req, tag, f.modified));
    var out: u8[>..] = [];
    var keep = true;
    var st = http::Stream { .. };
    var body = http::FileBody { .. };
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: 1, head: false, stream: st };
    http::serve_file(req, reply, f, "a/b", body);
    assert(find(out, "304 Not Modified") >= 0 && body.fd == -1);
    print("file_tag: serve_file's ETag, and its 304");
    assert(delete_file(name));
}
