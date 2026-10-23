// Which coding a request gets (coding_for), and which content types are
// compressible.
import std;
import http from "../../";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import http.compression;
import check from "../";

struct Pick { fields: const u8[:], coding: http::Coding }

fn main() {
    let c = http::Compression { .. };
    let cases = [
        Pick { fields: "", coding: http::Coding.Identity },
        Pick { fields: "Accept-Encoding: gzip, br\r\n", coding: http::Coding.Gzip },
        Pick { fields: "Accept-Encoding: gzip, deflate, br, zstd\r\n", coding: http::Coding.Zstd },
        Pick { fields: "Accept-Encoding: deflate\r\n", coding: http::Coding.Deflate },
        Pick { fields: "Accept-Encoding: deflate, gzip\r\n", coding: http::Coding.Gzip },
        Pick { fields: "Accept-Encoding: zstd;q=0.5, gzip\r\n", coding: http::Coding.Gzip },
        Pick { fields: "Accept-Encoding: br\r\n", coding: http::Coding.Identity },
        Pick { fields: "Accept-Encoding: *\r\n", coding: http::Coding.Zstd },
        Pick { fields: "Accept-Encoding: identity\r\n", coding: http::Coding.Identity },
    ];
    for k in cases {
        var b: u8[>..] = [];
        let r = check::request("GET", k.fields, b);
        if http::coding_for(r, c) != k.coding { print("coding_for: ", k.fields); }
        assert(http::coding_for(r, c) == k.coding);
    }
    var b: u8[>..] = [];
    let r = check::request("GET", "Accept-Encoding: zstd, gzip;q=0.9\r\n", b);
    assert(http::coding_for(r, http::Compression { zstd: false, .. }) == http::Coding.Gzip);
    print("coding_for: ", cases.len, " cases, and gzip with zstd turned off");

    assert(http::compressible("application/json"));
    assert(http::compressible("text/html; charset=utf-8"));
    assert(http::compressible("image/svg+xml"));
    assert(!http::compressible("image/png"));
    assert(!http::compressible("Video/mp4"));
    assert(!http::compressible("application/zip"));
    assert(!http::compressible("font/woff2"));
    print("compressible: JSON, HTML, SVG; not PNG, MP4, zip, WOFF2");
}
