module utils;

import core.thread;
import std.stdio;
import std.traits;
import std.experimental.allocator;

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


bool notifyAndWait(shared(bool)[] flags, size_t myIndex, Fiber ctxSwitch, ref shared(bool) killswitch)
{
    import core.atomic;

    atomicStore(flags[myIndex], true);

    // 他のスレッドがすべて準備完了するまでwhileで待つ
    while(!atomicLoad(killswitch)) {
        bool check = true;
        foreach(ref b; flags)
            check = check && atomicLoad(b);

        if(check)
            return true;

        if(ctxSwitch !is null)
            ctxSwitch.yield();
    }

    return false;
}


bool waitDone(ref shared(bool) flag, Fiber ctxSwitch, ref shared(bool) killswitch)
{
    import core.atomic;

    while(!atomicLoad(killswitch)) {
        if(atomicLoad(flag))
            return true;

        if(ctxSwitch !is null)
            ctxSwitch.yield();
    }

    return false;
}


struct BinaryReader
{
    const(ubyte)[] buffer;

    size_t length()
    {
        return buffer.length;
    }


    bool canRead(T)()
    {
        return buffer.length >= T.sizeof;
    }


    bool canReadArray(E)(size_t n)
    {
        return buffer.length >= E.sizeof * n;
    }


    T read(T)()
    {
        T dst = (cast(T[])cast(void[])(buffer[0 .. T.sizeof]))[0];
        buffer = buffer[T.sizeof .. $];
        return dst;
    }


    const(E)[] readArray(E)(size_t n)
    {
        const(E)[] dst = cast(const(E)[])cast(void[])(buffer[0 .. E.sizeof * n]);
        buffer = buffer[E.sizeof * n .. $];
        return dst;
    }
}


struct ReadOnlyArray(E)
{
    import std.range;

    inout(E) front() inout { return _array.front; }
    void popFront() { _array.popFront(); }
    bool empty() const { return _array.empty; }
    inout(E) opIndex(size_t i) inout { return _array[i]; }
    size_t length() const { return _array.length; }
    inout(ReadOnlyArray!E) opSlice(size_t i, size_t j) inout { return inout(ReadOnlyArray!E)(_array[i .. j]); }
    size_t opDollar() const { return _array.length; }

    int opApply(scope int delegate(E) dg) 
    {
        int result = 0;
        foreach (e; _array)
        {
            result = dg(e);
            if(result)
                return result;
        }

        return result;
    }


    int opApply(scope int delegate(size_t, E) dg)
    {
        int result = 0;
        foreach (i, e; _array)
        {
            result = dg(i, e);
            if(result)
                break;
        }
    
        return result;
    }

  private:
    E[] _array;
}


auto readOnlyArray(E)(E[] arr)
{
    return ReadOnlyArray!E(arr);
}


unittest
{
    auto arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    auto r = readOnlyArray(arr);
    assert(r[5 .. $].front == 6);
    foreach(i, e; r) {
        if((i+1) >= 3) break;
        assert(e < 3);
    }
}


auto makeUniqueArray(T)(size_t n)
{
    return UniqueArray!T(n);
}


private void _disposeAll(alias alloc, U)(ref U[] arr)
{
    if(arr is null) return;

    static if(isArray!U) {
        foreach(ref e; arr)
            ._disposeAll!alloc(e);
    }

    alloc.dispose(arr);
    arr = null;
}


struct UniqueArray(T)
{
    import std.traits : isArray, ForeachType;
    import std.experimental.allocator;
    import std.experimental.allocator.mallocator;
    alias alloc = Mallocator.instance;

    @disable this(this);
    @disable void opAssign(UniqueArray);


    ~this()
    {
        if(_array.ptr is null) return;
        _disposeAll!alloc(_array);
    }


    this(size_t n)
    {
        _array = alloc.makeArray!(T)(n);
    }


  static if(isArray!T)
  {
    void opIndexAssign(UniqueArray!(ForeachType!T) arr, size_t i)
    in(i < _array.length)
    {
        _disposeAll!alloc(_array[i]);
        _array[i] = arr.array;
        arr._array = null;
    }
  }


    inout(T)[] array() inout { return _array; }

  private:
    T[] _array;
}


unittest
{
    auto int2d = makeUniqueArray!(int[])(3);
    foreach(i; 0 .. 3)
        int2d[i] = makeUniqueArray!int(2);

    assert(int2d.array.length == 3);
    foreach(i; 0 .. 3)
        assert(int2d.array[i].length == 2);
}