module utils;

import std.stdio;

template debugMsg(string tag)
{
    enum string _tag_ = "[" ~ tag ~ "] ";

    void writef(T...)(string fmt, T args)
    {
        debug std.stdio.writef(_tag_ ~ fmt, args);
    }

    void writef(string fmt, T...)(T args)
    {
        debug std.stdio.writef!(_tag_ ~ fmt)(args);
    }

    void writefln(T...)(string fmt, T args)
    {
        debug std.stdio.writefln(_tag_ ~ fmt, args);
    }

    void writefln(string fmt, T...)(T args)
    {
        debug std.stdio.writefln!(_tag_ ~ fmt)(args);
    }

    void write(T...)(T args)
    {
        debug std.stdio.write(_tag_, args);
    }

    void writeln(T...)(T args)
    {
        debug std.stdio.writeln(_tag_, args);
    }
}


void notifyAndWait(shared(bool)[] flags, size_t myIndex)
{
    import core.atomic;

    atomicStore(flags[myIndex], true);

    // 他のスレッドがすべて準備完了するまでwhileで待つ
    while(1) {
        bool check = true;
        foreach(ref b; flags)
            check = check && atomicLoad(b);

        if(check)
            break;
    }
}
