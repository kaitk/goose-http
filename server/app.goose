// The benchmark server: TechEmpower's and HttpArena's routes (routes.goose),
// served by either of the package's loops, and task 002's echo servers.
// server.goose and server_epoll.goose are its root files, which differ in the
// loop they serve with when LOOP doesn't name one, and server_tls.goose is
// server_epoll.goose with the TLS listener, on either loop.
import std;
import os;
import http;
import routes;
import echo;
import dataset;

fn usage() {
    write_stderr("usage: server http|echo-blocking|echo-epoll [port]\n");
    exit(2);
}

// Runs the mode the command line names. The http mode serves with the loop
// LOOP names, epoll or uring (iocp on Windows, the same loop), or with
// default_loop without it. uring-epoll is the uring loop over the emulation
// it falls back to where io_uring is blocked, and uring-direct the uring loop
// with direct descriptors (Config.ring_direct). TLS adds the TLS listener, if
// the root file serves one (https.goose), and WORKERS runs the workers,
// given cfg and whether the loop is epoll.
fn run<TLS, WORKERS>(default_loop: const u8[:]) {
    let argv = args();
    guard argv.len >= 2 else { usage(); }
    var port: i32 = 8080;
    if argv.len > 2 {
        let p, ok = parse_int(argv[2]);
        guard ok && p > 0 && p < 65536 else { usage(); }
        port = p as i32;
    }
    let mode = argv[1];
    if mode == "http" {
        // A body may be as long as /upload's tests send. The timeouts and
        // the cap on a connection's requests are the package's unless the
        // environment names others, for the tests, and ACCESS_LOG turns the
        // access log on.
        var cfg = http::Config { port: port, workers: positive("WORKERS", 0), max_body: 1 << 30, .. };
        cfg.request_ms = positive("REQUEST_MS", cfg.request_ms);
        cfg.body_ms = positive("BODY_MS", cfg.body_ms);
        cfg.write_ms = positive("WRITE_MS", cfg.write_ms);
        cfg.idle_ms = positive("IDLE_MS", cfg.idle_ms);
        cfg.max_requests = positive("MAX_REQUESTS", cfg.max_requests);
        cfg.max_conns = positive("MAX_CONNS", cfg.max_conns);
        var logging: u8[>..] = [];
        cfg.log = env("ACCESS_LOG", logging);
        // MAIL_SLOTS turns on answers that wait, for /later and /events,
        // with MAX_WAITING exchanges waiting at once per worker.
        cfg.mail_slots = positive("MAIL_SLOTS", 0) as i32;
        cfg.max_waiting = positive("MAX_WAITING", if cfg.mail_slots > 0 { 1024 } else { 0 });
        cfg.mail_size = REPLY_SIZE;
        // ADDRESS is where to listen, as Config.address takes it: an IPv4 or
        // IPv6 address, "::", or "unix:PATH". IPV6_ONLY keeps "::" off IPv4.
        var address: u8[>..] = [];
        if env("ADDRESS", address) {
            guard address.len <= 112 else {
                write_stderr("ADDRESS is longer than 112 bytes\n");
                exit(2);
            }
            cfg.address.append(address);
        }
        var v6only: u8[>..] = [];
        cfg.ipv6_only = env("IPV6_ONLY", v6only);
        serve_http(cfg, default_loop, TLS, WORKERS);
    }
    else if mode == "echo-blocking" { echo_blocking(port); }
    else if mode == "echo-epoll" { echo_epoll(port); }
    else { usage(); }
}

// A loop that fails ends the process. One that a stop ended returns, and the
// process ends once every worker has.
thread_fn worker(cfg: http::Config) { http::exit_on_error(http::serve(cfg, Transfer { .. }, handle)); }

thread_fn worker_epoll(cfg: http::Config) { http::exit_on_error(http::serve_epoll(cfg, Transfer { .. }, handle)); }

// A root file's TLS and WORKERS for run, without TLS.
fn no_tls(cfg: http::Config&, also: u8[>..]&) {}
fn workers(cfg: http::Config, epoll: bool) {
    if epoll { http::run(cfg, worker_epoll); } else { http::run(cfg, worker); }
}

fn serve_http<TLS, WORKERS>(given: http::Config, default_loop: const u8[:]) {
    // SIGTERM and SIGINT stop the workers gracefully.
    http::exit_on_error(http::stop_on_signals());
    var cfg = given;
    var name: u8[>..] = [];
    if !env("LOOP", name) { name.append(default_loop); }
    let epoll = name == "epoll";
    cfg.emulate_ring = name == "uring-epoll";
    cfg.ring_direct = name == "uring-direct";
    guard epoll || cfg.emulate_ring || cfg.ring_direct || name == "uring" || name == "iocp" else {
        write_stderr("LOOP must be epoll, uring, uring-epoll, uring-direct, or iocp\n");
        exit(2);
    }
    // The server also serves h2c, HTTP/2 with prior knowledge, on H2C_PORT,
    // by default the port + 2, as HttpArena's 8082 is beside 8080, where its
    // loop takes a second listener: not on Windows (ring_listeners).
    // H2C_PORT=0 turns it off.
    var also: u8[>..] = [];
    var h2c_port: u8[>..] = [];
    var p: i64 = cfg.port as i64 + 2;
    if env("H2C_PORT", h2c_port) {
        let n, ok = parse_int(h2c_port);
        guard ok && n >= 0 && n < 65536 else {
            write_stderr("H2C_PORT must be a port number, or 0 for none\n");
            exit(2);
        }
        p = n;
    }
    if (epoll || http::ring_listeners() > 1) && p > 0 && p < 65536 && !starts_with(cfg.address, "unix:") {
        cfg.listeners.push(http::Listener { port: p as i32, h2c: true });
        format(also, ", h2c on port ", p);
    }
    if !starts_with(cfg.address, "unix:") { TLS(cfg, also); }
    let n = http::worker_count(cfg);
    load_dataset();
    // WS_LIMIT is /ws's longest message, which each connection is promised
    // of its worker's gather budget at its upgrade; Autobahn's tests set it.
    spare.limit = positive("WS_LIMIT", spare.limit);
    // The backend lane of /later and /events, one thread that serves every worker.
    if cfg.mail_slots > 0 {
        backend_lane = http::lane_open(http::LaneConfig { slots: 256, size: JOB_SIZE, .. }, 4096, backend);
    }
    // Where io_uring is blocked, the uring loop runs over an emulation, and
    // says so.
    var ring: u8[>..] = [];
    let probe = if epoll { 0 } else { http::ring_probe() };
    if probe < 0 && !cfg.emulate_ring {
        var text: u8[128] = [0; 128];
        let k = http::net_strerror(-probe, text);
        format(ring, " on an emulated ring (io_uring_setup: ", text[..k], ")");
    }
    // SERVER_RUNS serves again after each stop, for testing a loop called
    // again. Not RUNS, which the benchmark scripts set for themselves.
    for run in positive("SERVER_RUNS", 1) {
        print("http: ", n, if n == 1 { " worker" } else { " workers" }, " on port ", cfg.port,
              if cfg.address.len > 0 { " at " } else { "" }, cfg.address, also, ", ", name, " loop", ring);
        WORKERS(cfg, epoll);
    }
    http::lane_stop(backend_lane);
}

// The environment variable name, a positive number, or otherwise without it.
fn positive(name: const u8[:], otherwise: i64) -> i64 {
    var v: u8[>..] = [];
    guard env(name, v) else { return otherwise; }
    let n, ok = parse_int(v);
    guard ok && n > 0 else {
        write_stderr(str(name, " must be a positive number\n"));
        exit(2);
    }
    return n;
}
