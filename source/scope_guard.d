module scope_guard;

__EOF__

import core.stdc.signal;
import core.atomic;
import core.stdc.stdio;

shared static void delegate()[ulong] shutdownHandlerList;
shared static ulong shutdownHandlerIdCounter = 0;

shared static this()
{
    alias Fn = extern(C) void function(int) nothrow @nogc;
    signal(SIGINT, cast(Fn)&handleSigint);
}


extern(C) void handleSigint(int signum)
{
    if(signum == SIGINT) {
        printf("Received SIGINT, executing shutdown handlers...\n");
        fflush(stdout);

        // まずは各種終了処理を呼び出す
        foreach(_, handler; shutdownHandlerList) {
            handler();
        }

        shutdownHandlerList = null;

        // ハンドラをデフォルトに戻して再度SIGINTを送る
        signal(SIGINT, SIG_DFL);
        raise(SIGINT);
    }
}


class ScopeGuard
{
    static synchronized ScopeGuardId scope_exit(void delegate() handler)
    {
        ulong id = shutdownHandlerIdCounter;
        shutdownHandlerIdCounter.atomicOp!"+="(1);

        shutdownHandlerList[id] = handler;
        return ScopeGuardId(id);
    }
}


struct ScopeGuardId
{
    ulong _id;

    ~this()
    {
        shutdownHandlerList.remove(this._id);
    }
}
