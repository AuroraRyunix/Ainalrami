/*
 * ainalrami.exe - the command line, for people who have no Erlang.
 *
 * It stands at the top of the release folder and does one job: start the
 * Erlang runtime that is in that folder, hand it the arguments it was given,
 * and exit with whatever the runtime exits with. There is no window, no
 * service and no installer; the console it was started from is the console
 * the pairings are printed on, so redirects and pipes behave like those of
 * any other program.
 *
 * Built by `zig cc` (see .github/workflows/release.yml), CONSOLE subsystem.
 * Not the Windows subsystem: that one detaches from the console and a pairing
 * engine that prints into the void is a poor engine.
 *
 * It does not use bin\ainalrami.bat. A batch file would read the arguments a
 * second time with cmd.exe's rules, and a TRF in a folder with an ampersand
 * in its name deserves better. It reads releases\start_erl.data for the two
 * version numbers and runs erts-<vsn>\bin\erl.exe directly:
 *
 *   erl.exe -noshell -boot releases\<vsn>\start -boot_var RELEASE_LIB lib
 *           -config releases\<vsn>\sys.config
 *           -eval "'Elixir.Ainalrami.CLI':main(...)" -extra <your arguments>
 *
 * Ainalrami.CLI.main/1 halts the VM with the CLI's exit code, which is
 * therefore ours.
 *
 * Every argument is quoted for CreateProcess by the usual rules (backslashes
 * only count before a quote), so what Erlang sees is what you typed.
 */

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define MAXP 4096
#define CMDCAP 32768

/* Appends s to buf as one CreateProcess argument, quoted. */
static void put_arg(WCHAR *buf, size_t cap, const WCHAR *s)
{
    size_t n = wcslen(buf);
    size_t i;
    unsigned backslashes = 0;

    if (n + 3 >= cap) return;
    if (n > 0) buf[n++] = L' ';
    buf[n++] = L'"';
    for (i = 0; s[i]; i++) {
        if (s[i] == L'\\') {
            backslashes++;
        } else if (s[i] == L'"') {
            /* Backslashes before a quote are doubled, then the quote is escaped. */
            while (backslashes-- > 0 && n + 3 < cap) { buf[n++] = L'\\'; buf[n++] = L'\\'; }
            if (n + 3 < cap) { buf[n++] = L'\\'; buf[n++] = L'"'; }
            backslashes = 0;
        } else {
            while (backslashes-- > 0 && n + 2 < cap) buf[n++] = L'\\';
            if (n + 2 < cap) buf[n++] = s[i];
            backslashes = 0;
        }
    }
    /* Backslashes before the closing quote are doubled too. */
    while (backslashes-- > 0 && n + 3 < cap) { buf[n++] = L'\\'; buf[n++] = L'\\'; }
    buf[n++] = L'"';
    buf[n] = 0;
}

static int fail(const WCHAR *what)
{
    fwprintf(stderr, L"ainalrami: %ls\n", what);
    return 70;
}

int wmain(int argc, wchar_t **argv)
{
    static WCHAR cmd[CMDCAP];
    WCHAR self[MAXP], root[MAXP], data_path[MAXP], erl[MAXP], p[MAXP];
    WCHAR erts_vsn[64] = L"", rel_vsn[64] = L"";
    WCHAR *slash;
    char raw[256], *sp, *end;
    size_t len;
    FILE *f;
    int i;
    HANDLE job;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 70;

    /* Where we are, never the working directory. */
    len = GetModuleFileNameW(NULL, self, MAXP);
    if (len == 0 || len >= MAXP) return fail(L"cannot work out where ainalrami.exe is");
    wcscpy(root, self);
    slash = wcsrchr(root, L'\\');
    if (!slash) return fail(L"cannot work out where ainalrami.exe is");
    *slash = 0;

    /* releases\start_erl.data is "<erts version> <release version>". */
    _snwprintf(data_path, MAXP, L"%ls\\releases\\start_erl.data", root);
    f = _wfopen(data_path, L"rb");
    if (!f) return fail(L"releases\\start_erl.data is missing: this folder is not a whole Ainalrami release");
    len = fread(raw, 1, sizeof(raw) - 1, f);
    fclose(f);
    raw[len] = 0;
    sp = strchr(raw, ' ');
    if (!sp) return fail(L"releases\\start_erl.data is not what was expected");
    *sp = 0;
    sp++;
    for (end = sp; *end && *end != '\r' && *end != '\n'; end++) {}
    *end = 0;
    if (strlen(raw) > 60 || strlen(sp) > 60) return fail(L"releases\\start_erl.data is not what was expected");
    MultiByteToWideChar(CP_UTF8, 0, raw, -1, erts_vsn, 64);
    MultiByteToWideChar(CP_UTF8, 0, sp, -1, rel_vsn, 64);

    _snwprintf(erl, MAXP, L"%ls\\erts-%ls\\bin\\erl.exe", root, erts_vsn);
    if (GetFileAttributesW(erl) == INVALID_FILE_ATTRIBUTES)
        return fail(L"the Erlang runtime (erts) is missing from this folder");

    cmd[0] = 0;
    put_arg(cmd, CMDCAP, erl);
    put_arg(cmd, CMDCAP, L"-noshell");
    put_arg(cmd, CMDCAP, L"-boot");
    _snwprintf(p, MAXP, L"%ls\\releases\\%ls\\start", root, rel_vsn);
    put_arg(cmd, CMDCAP, p);
    put_arg(cmd, CMDCAP, L"-boot_var");
    put_arg(cmd, CMDCAP, L"RELEASE_LIB");
    _snwprintf(p, MAXP, L"%ls\\lib", root);
    put_arg(cmd, CMDCAP, p);
    put_arg(cmd, CMDCAP, L"-config");
    _snwprintf(p, MAXP, L"%ls\\releases\\%ls\\sys.config", root, rel_vsn);
    put_arg(cmd, CMDCAP, p);
    put_arg(cmd, CMDCAP, L"-eval");
    put_arg(cmd, CMDCAP,
        L"'Elixir.Ainalrami.CLI':main([unicode:characters_to_binary(A)||A<-init:get_plain_arguments()])");
    put_arg(cmd, CMDCAP, L"-extra");
    for (i = 1; i < argc; i++) put_arg(cmd, CMDCAP, argv[i]);

    /* No crash dump in the folder the user happened to be standing in. */
    if (!GetEnvironmentVariableW(L"ERL_CRASH_DUMP_SECONDS", NULL, 0))
        SetEnvironmentVariableW(L"ERL_CRASH_DUMP_SECONDS", L"0");
    /* The runtime finds itself from its own path; a stray ROOTDIR from some
     * other Erlang on this machine would send it elsewhere. */
    SetEnvironmentVariableW(L"ROOTDIR", NULL);
    SetEnvironmentVariableW(L"BINDIR", NULL);

    /* The runtime dies with us: a killed launcher must not leave a beam
     * behind. */
    job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION li;
        memset(&li, 0, sizeof(li));
        li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof(li));
    }

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    /* Console handles are inherited: stdin, stdout and stderr go straight
     * through, pipes and redirects included. */
    if (!CreateProcessW(erl, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi))
        return fail(L"could not start the Erlang runtime");
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);

    /* Ctrl-C belongs to the child; do not die before it has said goodbye. */
    SetConsoleCtrlHandler(NULL, TRUE);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
