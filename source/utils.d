module utils;

import core.thread;
import core.lifetime;

import std.stdio;
import std.traits;
import std.experimental.allocator;
import std.meta;

import multithread;



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
        foreach (i, ref e; _array)
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

    auto unq = cast(Unqual!U[])arr;
    alloc.dispose(unq);
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


    ~this()
    {
        if(_array.ptr is null) return;
        ArrayType arr = cast(ArrayType)_array;
        _disposeAll!(alloc, dim)(arr);
        _array = null;
    }


    this(size_t n)
    {
        _array = cast(shared) alloc.makeArray!(ForeachType)(n);
    }


    private
    this(inout shared(ForeachType)[] arr) inout
    {
        this._array = arr;
    }


  static if(dim > 1)
  {
    void opIndexAssign(UniqueArray!(E, dim-1) arr, size_t i)
    in(i < _array.length)
    {
        auto ei = cast(ForeachType) _array[i];
        _disposeAll!(alloc, dim-1)(ei);
        this.array[i] = arr.array;
        arr._array = null;
    }


    UniqueArray!(E, dim-1) moveAt(size_t i)
    in(i < _array.length)
    {
        UniqueArray!(E, dim-1) ret;
        ret._array = cast(shared)this.array[i];
        this.array[i] = null;
        return ret;
    }


    UniqueArray!(E, dim) moveSlice(size_t i, size_t j)
    in(i < j) in(i <= _array.length) in(j <= _array.length)
    {
        auto ret = UniqueArray!(E, dim)(j - i);
        foreach(k; i .. j) {
            ret[k - i] = this.moveAt(k);
        }
        return ret;
    }
  }
  else
  {
    ref inout(E) opIndex(size_t i) inout
    {
        return (cast(inout(ArrayType))this._array)[i];
    }

    
    ref Select!(isShareable!E, inout(E), shared(inout(E))) opIndex(size_t i) inout shared
    {
        return (cast(typeof(return)[]) this._array)[i];
    }
  }


    inout(ArrayType) array() inout { return cast(inout(ArrayType))_array; }
    Select!(isShareable!E, inout(ArrayType), shared(inout(ArrayType))) array() inout shared { return cast(typeof(return)) _array; }
    immutable(ArrayType) array() immutable { return cast(immutable(ArrayType))_array; }


    size_t length() const { return _array.length; }
    size_t length() const shared { return _array.length; }
    size_t length() immutable { return _array.length; }


    void resize(size_t newlen)
    {
        static if(dim > 1) if(newlen < _array.length) {
            foreach(i; newlen .. _array.length) {
                auto ei = cast(ForeachType)_array[i];
                _disposeAll!(alloc, dim-1)(ei);
                this.array[i] = null;
            }
        }

        auto arr = cast(ArrayType)_array;
        if(newlen < _array.length) {
            alloc.shrinkArray(arr, _array.length - newlen);
        } else {
            alloc.expandArray(arr, newlen - _array.length);
        }
        _array = cast(typeof(this._array))arr;
    }


    void opAssign(UniqueArray rhs)
    {
        auto arr = cast(ArrayType)_array;
        if(_array !is null) ._disposeAll!(alloc, dim)(arr);
        _array = rhs._array;
        rhs._array = null;
    }


  static if(isLvalueAssignable!(E, const(E)))
  {
    typeof(this) dup() const
    {
        UniqueArray ret;
        ret._array = cast(typeof(ret._array)) _duplicateAll(cast(const(ArrayType)) _array);
        return ret;
    }
  }
  else static if(isLvalueAssignable!E)
  {
    typeof(this) dup()
    {
        UniqueArray ret;
        ret._array = cast(typeof(ret._array)) _duplicateAll(cast(ArrayType) _array);
        return ret;
    }
  }

  static if(is(E : immutable(E)))
  {
    immutable(UniqueArray!(E, dim)) moveAsImmutable()
    {
        auto arr = this._array;
        this._array = null;
        return immutable UniqueArray!(E, dim)(cast(immutable) arr);
    }
  }


  private:

  static if(isShareable!E)
    shared(ForeachType)[] _array;
  else
    ArrayType _array;


    private static ArrayType _duplicateAll(T)(scope T arr)
    if((is(T : const(ArrayType)) && isLvalueAssignable!(E, const(E)))
    || (is(T : ArrayType) && isLvalueAssignable!(E, E)))
    {
        if(arr is null) return null;

        ArrayType dst = alloc.makeArray!(ForeachType)(arr.length);
        static if(dim > 1) {
            foreach(i; 0 .. arr.length)
                dst[i] = UniqueArray!(E, dim-1)._duplicateAll(arr[i]);
        } else {
            foreach(i; 0 .. arr.length)
                dst[i] = arr[i];
        }

        return dst;
    }
}

unittest
{
    auto arr = makeUniqueArray!int(3);
    assert(arr.length == 3);
    arr[0] = 1;
    arr[1] = 2;
    arr[2] = 3;
    assert(arr[0] == 1 && arr[1] == 2 && arr[2] == 3);

    auto arr2 = arr.dup;
    assert(arr2[0] == 1 && arr2[1] == 2 && arr[2] == 3);

    auto p1 = arr._array.ptr;
    auto p2 = arr2._array.ptr;
    assert(p1 !is p2);

    arr = move(arr2);
    assert(arr._array.ptr is p2);

    arr.resize(2);
    assert(arr.length == 2);
    assert(arr[0] == 1 && arr[1] == 2);

    arr.resize(4);
    assert(arr.length == 4);
    assert(arr[0] == 1 && arr[1] == 2 && arr[2] == 0 && arr[3] == 0);
}

unittest
{
    auto int2d = makeUniqueArray!(int, 2)(3);
    foreach(i; 0 .. 3) {
        auto e =  makeUniqueArray!int(2);
        e[0] = (i + 1);
        e[1] = (i + 1) * 2;
        int2d[i] = move(e);
    }

    assert(int2d.array.length == 3);
    foreach(i; 0 .. 3)
        assert(int2d.array[i].length == 2);

    auto int1d = int2d.moveAt(0);
    assert(int2d.array[0].length == 0);
    assert(int1d.array.length == 2);

    assert(int1d[0] == 1 && int1d[1] == 2);

    int2d[0] = move(int1d);
    int2d.resize(1);
    assert(int2d.length == 1);
    assert(int2d.array[0].length == 2);
    int2d.resize(2);
    assert(int2d.length == 2);
    assert(int2d.array[0].length == 2 && int2d.array[1].length == 0);
    assert(int2d.array[0][0] == 1 && int2d.array[0][1] == 2);

    auto int2ddup = int2d.dup;
    assert(int2ddup.length == 2);
    assert(int2ddup.array[0].length == 2 && int2ddup.array[1].length == 0);
    assert(int2ddup.array[0][0] == 1 && int2ddup.array[0][1] == 2);

    immutable imm = int2ddup.moveAsImmutable;
    assert(imm.length == 2);
    assert(imm.array[0].length == 2 && imm.array[1].length == 0);
    assert(imm.array[0][0] == 1 && imm.array[0][1] == 2);
}

unittest
{
    auto int2d = makeUniqueArray!(int, 2)(3);
    foreach(i; 0 .. 3) {
        auto e =  makeUniqueArray!int(2);
        e[0] = (i + 1);
        e[1] = (i + 1) * 2;
        int2d[i] = move(e);
    }

    auto mv1 = int2d.moveSlice(0, 1);
    assert(mv1.length == 1);
    assert(mv1.array[0].length == 2);
    assert(mv1.array[0][0] == 1 && mv1.array[0][1] == 2);

    auto mv2 = int2d.moveSlice(1, 3);
    assert(mv2.length == 2);
    assert(mv2.array[0].length == 2);
    assert(mv2.array[0][0] == 2 && mv2.array[0][1] == 4);
    assert(mv2.array[1][0] == 3 && mv2.array[1][1] == 6);
}