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

    int opApply(Fn)(scope Fn dg)
    {
        int result = 0;
        foreach (i, e; _array)
        {
            static if(is(typeof(dg(i, e))))
                result = dg(i, e);
            else
                result = dg(e);

            if(result)
                return result;
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
    foreach(size_t i, int e; r) {
        if((i+1) >= 3) break;
        assert(e < 3);
    }
}


auto makeUniqueArray(T, size_t dim = 1)(size_t n)
{
    return UniqueArray!(T, dim)(n);
}


private void _disposeAll(alias alloc, size_t dim, U)(ref U[] arr)
if(dim >= 1)
{
    if(arr is null) return;

    static if(dim > 1) {
        foreach(ref e; arr)
            ._disposeAll!(alloc, dim-1)(e);
    }

    alloc.dispose(arr);
    arr = null;
}


struct UniqueArray(E, size_t dim = 1)
{
    import std.experimental.allocator;
    import std.experimental.allocator.mallocator;
    alias alloc = Mallocator.instance;


  static if(dim > 1)
  {
    alias ArrayType = UniqueArray!(E, dim-1).ArrayType[];
    alias ForeachType = UniqueArray!(E, dim-1).ArrayType;
  }
  else
  {
    alias ArrayType = E[];
    alias ForeachType = E;
  }


    @disable this(this);
    @disable void opAssign(UniqueArray);


    ~this()
    {
        if(_array.ptr is null) return;
        _disposeAll!(alloc, dim)(_array);
    }


    this(size_t n)
    {
        _array = alloc.makeArray!(ForeachType)(n);
    }


  static if(dim > 1)
  {
    void opIndexAssign(UniqueArray!(E, dim-1) arr, size_t i)
    in(i < _array.length)
    {
        _disposeAll!(alloc, dim-1)(_array[i]);
        _array[i] = arr.array;
        arr._array = null;
    }
  }


    auto array() inout { return _array; }
    auto array() inout shared { return _array; }


    size_t length() const { return _array.length; }
    size_t length() const shared { return _array.length; }


    void resize(size_t newlen)
    {
        static if(dim > 1) if(newlen < _array.length) {
            foreach(i; newlen .. _array.length) {
                _disposeAll!(alloc, dim-1)(_array[i]);
            }
        }

        if(newlen < _array.length) {
            alloc.shrinkArray(_array, _array.length - newlen);
        } else {
            alloc.expandArray(_array, newlen - _array.length);
        }
    }

  private:
    ArrayType _array;
}


unittest
{
    auto int2d = makeUniqueArray!(int, 2)(3);
    foreach(i; 0 .. 3)
        int2d[i] = makeUniqueArray!int(2);

    assert(int2d.array.length == 3);
    foreach(i; 0 .. 3)
        assert(int2d.array[i].length == 2);
}