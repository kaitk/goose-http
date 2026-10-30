// A datagram the kernel refuses for its destination, here port 0, which a
// client's address can claim, is dropped from the worker's queue, as if
// lost: the datagrams of other connections behind it go out. On loopback
// sockets.
import std;
import os;
import http from "../../";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.tls;
import http.h3;

// 127.0.0.1:port as the kernel takes it: AF_INET is a byte after the
// address's length on macOS, and two bytes, little-endian, on Linux, which
// refuses the macOS form.
fn loopback(port: i32, macos: bool) -> http::UdpPeer {
    var p = http::UdpPeer { len: 16, addr: [0; 28] };
    if macos {
        p.addr[0] = 16;
        p.addr[1] = 2;
    } else {
        p.addr[0] = 2;
    }
    p.addr[2] = ((port >> 8) & 255) as u8;
    p.addr[3] = (port & 255) as u8;
    p.addr[4] = 127;
    p.addr[7] = 1;
    return p;
}

fn main() {
    let any: u8[0] = [];
    let fd = http::net_udp_open(any, 0, 0);
    let rfd = http::net_udp_open(any, 0, 0);
    assert(fd >= 0 && rfd >= 0);
    http::h3fds.push(fd);
    let dg: u8[1200] = [7; 1200];
    // Which form, from a datagram to the sender's own port.
    let one: i32[1] = [1];
    let macos = http::net_udp_send(fd, dg[..1], one, [loopback(http::net_port(fd), true)], false) == 1;
    let good = loopback(http::net_port(rfd), macos);
    let refused = loopback(0, macos);
    assert(http::h3_tx_begin(0, refused));
    http::h3_tx_end(0, refused, dg);
    for i in 3 {
        assert(http::h3_tx_begin(0, good));
        http::h3_tx_end(0, good, dg);
    }
    http::h3_send_now();
    var got = 0;
    var buf: u8[2048] = [0; 2048];
    for wait in 1000 {
        while http::net_recv(rfd, buf) > 0 { got++; }
        if got == 3 { break; }
        sleep_ms(1);
    }
    print("one datagram to port 0 ahead of 3 to a receiver: ", got, " received, ", http::h3tx_count, " left queued");
}
