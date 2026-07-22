"""Platform-aware signal narration shared by the report layer.

Signal numbers are target ABI facts, so reporters ask this module for the
human-readable name instead of carrying platform assumptions of their own.
"""

from std.sys.info import CompilationTarget


def _signal_name_for_platform(signo: Int, is_macos: Bool) -> String:
    """The common signal name and description for one explicit platform.

    Covers the closed set of terminating signals the reporters narrate.
    Returns an owned empty string outside that set so callers can retain the
    bare signal number.

    Args:
        signo: The terminating signal number.
        is_macos: Whether to interpret `signo` with Darwin's signal ABI rather
            than Linux's.

    Returns:
        An owned `"SIGNAME, description"` string, or `""` when unnamed.
    """
    if signo == 1:
        return String("SIGHUP, hangup")
    if signo == 2:
        return String("SIGINT, interrupt")
    if signo == 3:
        return String("SIGQUIT, quit")
    if signo == 4:
        return String("SIGILL, illegal instruction")
    if signo == 5:
        return String("SIGTRAP, trace/breakpoint trap")
    if signo == 6:
        return String("SIGABRT, abort")
    if signo == 7:
        if is_macos:
            return String("SIGEMT, emulation trap")
        return String("SIGBUS, bus error")
    if signo == 8:
        return String("SIGFPE, floating-point exception")
    if signo == 9:
        return String("SIGKILL, killed")
    if signo == 10 and is_macos:
        return String("SIGBUS, bus error")
    if signo == 11:
        return String("SIGSEGV, segmentation fault")
    if signo == 13:
        return String("SIGPIPE, broken pipe")
    if signo == 15:
        return String("SIGTERM, terminated")
    return String("")


def signal_name_for_target(signo: Int) -> String:
    """The common signal name and description for the compilation target.

    Args:
        signo: The terminating signal number.

    Returns:
        An owned `"SIGNAME, description"` string, or `""` when unnamed.
    """
    comptime if CompilationTarget.is_macos():
        return _signal_name_for_platform(signo, True)
    return _signal_name_for_platform(signo, False)
