const std = @import("std");
const os = std.os;
const EventLoop = @import("EventLoop.zig");

const SignalFile = @This();

loop: *EventLoop,
fd: os.fd_t,
old_set: os.sigset_t,

pub fn open(loop: *EventLoop, sigs: []const Signal) !SignalFile {
    var set = std.mem.zeroes(os.sigset_t);
    for (sigs) |sig| {
        os.linux.sigaddset(&set, @enumToInt(sig));
    }
    const fd = try os.signalfd(-1, &set, 0);

    var old_set: os.sigset_t = undefined;
    std.debug.assert(os.linux.sigprocmask(os.SIG_BLOCK, &set, &old_set) == 0);

    return SignalFile{ .loop = loop, .fd = fd, .old_set = old_set };
}

pub const Signal = enum(u6) {
    abrt = os.SIGABRT,
    alrm = os.SIGALRM,
    bus = os.SIGBUS,
    chld = os.SIGCHLD,
    cont = os.SIGCONT,
    fpe = os.SIGFPE,
    hup = os.SIGHUP,
    ill = os.SIGILL,
    int = os.SIGINT,
    io = os.SIGIO,
    // can't catch SIGKILL
    pipe = os.SIGPIPE,
    prof = os.SIGPROF,
    pwr = os.SIGPWR,
    quit = os.SIGQUIT,
    segv = os.SIGSEGV,
    stkflt = os.SIGSTKFLT,
    // can't catch SIGSTOP
    tstp = os.SIGTSTP,
    sys = os.SIGSYS,
    term = os.SIGTERM,
    trap = os.SIGTRAP,
    ttin = os.SIGTTIN,
    ttou = os.SIGTTOU,
    urg = os.SIGURG,
    usr1 = os.SIGUSR1,
    usr2 = os.SIGUSR2,
    vtalrm = os.SIGVTALRM,
    xcpu = os.SIGXCPU,
    xfsz = os.SIGXFSZ,
    winch = os.SIGWINCH,
};

pub fn close(self: SignalFile) void {
    std.debug.assert(os.linux.sigprocmask(os.SIG_SETMASK, &self.old_set, null) == 0);
    self.loop.close(self.fd);
}

pub fn capture(self: SignalFile) !os.signalfd_siginfo {
    const r = Reader{ .context = self };
    var info: os.signalfd_siginfo = undefined;
    try r.readNoEof(std.mem.asBytes(&info));
    return info;
}

fn read(self: SignalFile, buf: []u8) EventLoop.ReadError!usize {
    return try self.loop.read(self.fd, buf);
}
const Reader = std.io.Reader(SignalFile, EventLoop.ReadError, read);
