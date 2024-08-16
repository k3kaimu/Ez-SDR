module multithread;

import core.atomic;
import core.lifetime;
import core.time;

import std.traits;
import std.typecons;

import utils;


// alias SharedRef(T) = UnqualRef!(shared(T));

struct LocalRef(T)
if(is(T == shared))
{
    T value;

    this()(auto ref inout(T) v) inout
    {
        cast()this.value = cast()v;
    }

    alias get this;
    T get() { return cast(T)cast()this.value; }

    void opAssign(LocalRef rhs)
    {
        cast()this.value = cast()rhs.value;
    }

    void opAssign(T rhs)
    {
        cast()this.value = cast()rhs;
    }
}

unittest
{
    LocalRef!(shared(int*)) p1;
    p1 = new shared(int);
    shared(int)* p2 = p1;
}


enum bool isShareable(T) = isDelegate!T ? is(T == shared(T)) : is(T : shared(T));

unittest
{
    static assert(isShareable!int);
    static assert(isShareable!(shared(int)));
    static assert(isShareable!(shared(int)*));
    static assert(isShareable!(immutable(int)[]));
    static assert(isShareable!(shared(int)[]));
    static assert(!isShareable!(int*));

    static struct S1(T) { T a; }
    static assert(isShareable!(S1!int));
    static assert(isShareable!(shared(int)));
    static assert(isShareable!(S1!(shared(int)*)));
    static assert(isShareable!(S1!(immutable(int)[])));
    static assert(!isShareable!(S1!(int*)));

    static class C1 {}
    static assert(!isShareable!(C1));
    static assert(isShareable!(immutable(C1)));
    static assert(isShareable!(shared(C1)));

    static assert(isShareable!(void function()));
    static assert(isShareable!(shared(void delegate())));
    static assert(!isShareable!(void delegate()));
}


/// Locked Queue
final class LockQueue(T)
if(isShareable!T)
{
    import utils : UniqueArray;

    this(size_t initlen = 4096 / T.sizeof)
    {
        auto buf = makeUniqueArray!T(initlen);
        move(buf, cast()_data);
    }


    bool empty() shared const
    {
        return _wpos == _rpos;
    }


    synchronized size_t length() const
    {
        if(_wpos < _rpos)
            return (_wpos + _data.length) - _rpos;
        else
            return _wpos - _rpos;
    }


    synchronized bool pop(out T result)
    {
        if(_rpos == _wpos) return false;

        move(cast()_data.array[_rpos], result);
        _rpos = (_rpos + 1) % _data.length;
        return true;
    }


    synchronized void push(T result)
    {
        if(_rpos == (_wpos + 1) % _data.length) {
            immutable oldlen = _data.length;
            (cast()_data).resize(_data.length * 2);

            if(_wpos < _rpos) {
                foreach(i; 0 .. _wpos)
                    move(cast()_data.array[i], cast()_data.array[oldlen + i]);

                _wpos = oldlen + _wpos;
            }
        }

        move(result, cast()_data.array[_wpos]);
        _wpos = (_wpos + 1) % _data.length;
    }

  private:
    UniqueArray!T _data;
    size_t _rpos;
    size_t _wpos;
}

unittest
{
    shared(LockQueue!size_t) q1 = new LockQueue!size_t(1);
    size_t result = size_t.max;

    assert(!q1.pop(result));
    assert(result == typeof(result).init);

    shared(LockQueue!size_t) queue = new LockQueue!size_t(1);
    foreach(i; 0 .. 100) {
        size_t numTry = (i + 100)^^2 % 1000;
        foreach(n; 0 .. numTry)
            queue.push(n);

        foreach(n; 0 .. numTry) {
            assert(queue.pop(result));
            assert(result == n);
        }
    }
}


/// Lock-free Queue. See: https://kumagi.hatenablog.com/entry/ring-buffer
final class LockFreeSPSCQueue(T)
if(isShareable!T)
{
    import core.atomic;

    this(size_t size = 4096 / T.sizeof)
    {
        _data.length = size;
    }


    bool empty() shared const
    {
        immutable rpos = _rpos.atomicLoad!(MemoryOrder.raw);
        immutable wpos = _wpos.atomicLoad!(MemoryOrder.acq);

        if(wpos == rpos)
            return true;
        else
            return false;
    }


    bool filled() shared const
    {
        immutable wpos = _wpos.atomicLoad!(MemoryOrder.raw);
        immutable rpos = _rpos.atomicLoad!(MemoryOrder.acq);

        if(wpos - rpos == _data.length)
            return true;
        else
            return false;
    }


    size_t length() shared const { return _wpos - _rpos; }


    bool push(T item) shared
    {
        immutable wpos = _wpos.atomicLoad!(MemoryOrder.raw);
        immutable size = _data.length;

        if(wpos - _rpos_cached == size) {
            _rpos_cached = _rpos.atomicLoad!(MemoryOrder.acq);
            if(wpos - _rpos_cached == size)
                return false;
        }

        move(item, cast()_data[wpos & (_data.length - 1)]);
        _wpos.atomicStore!(MemoryOrder.rel)(wpos + 1);
        return true;
    }


    bool pop(out T item) shared
    {
        immutable rpos = _rpos.atomicLoad!(MemoryOrder.raw);
        immutable size = _data.length;

        if(_wpos_cached == rpos) {
            _wpos_cached = _wpos.atomicLoad!(MemoryOrder.acq);
            if(_wpos_cached == rpos)
                return false;
        }

        move(cast()_data[rpos & (size - 1)], item);
        _rpos.atomicStore!(MemoryOrder.rel)(rpos + 1);
        return true;
    }

  private:
    T[] _data;
    align(64) size_t _rpos;
    align(64) size_t _rpos_cached;
    align(64) size_t _wpos;
    align(64) size_t _wpos_cached;
}

unittest
{
    shared(LockFreeSPSCQueue!size_t) q1 = new LockFreeSPSCQueue!size_t(1024);
    size_t result = size_t.max;

    assert(!q1.pop(result));
    assert(result == typeof(result).init);

    shared(LockFreeSPSCQueue!size_t) queue = new LockFreeSPSCQueue!size_t(1024);
    foreach(i; 0 .. 100) {
        size_t numTry = (i + 100)^^2 % 1024;
        foreach(n; 0 .. numTry)
            assert(queue.push(n));

        assert(queue.length == numTry);

        foreach(n; 0 .. numTry) {
            assert(queue.pop(result));
            assert(result == n);
        }
    }
}


/** 単一スレッドからの書き込みと，単一スレッドからの読み込みを許す通知付きオブジェクト．
一度書き込みをすると，それ以降は読み取り専用となる．
*/
struct NotifiedLazy(T)
{
    import core.atomic;
    import core.sync.event;
    import std.experimental.allocator;


    static
    shared(NotifiedLazy)* make(Alloc)(ref Alloc alloc)
    {
        auto ptr = alloc.make!(NotifiedLazy)();
        ptr.initialize();
        return cast(shared)ptr;
    }


    static
    shared(NotifiedLazy)* make()
    {
        import std.experimental.allocator.mallocator;
        return NotifiedLazy.make!(shared(Mallocator))(Mallocator.instance);
    }


    static
    void dispose(Alloc)(NotifiedLazy* ptr, ref Alloc alloc)
    {
        ptr.terminate();
        alloc.dispose(ptr);
    }


    static
    void dispose(NotifiedLazy* ptr)
    {
        import std.experimental.allocator.mallocator;
        NotifiedLazy.dispose!(shared(Mallocator))(ptr, Mallocator.instance);
    }


    ~this()
    {
        this.terminate();
    }


    @disable this(this);
    @disable void opAssign(NotifiedLazy);


    void initialize()
    {
        _isNull = true;
        _nofity.initialize(true, false);
    }


    void terminate()
    {
        _nofity.terminate();
    }


    void write(T value) shared
    {
        // 一度書き込みをすると，それ以降は書き込めない
        if(!cas(&_isNull, true, false)) return;

        // ここ以降は必ず単一スレッドのみが実行できる
        _response = value;
        (cast()_nofity).setIfInitialized();
    }


    ref shared(T) read() shared
    {
        // 書き込みされるまで読み込めない
        (cast()_nofity).wait();
        assert(!_isNull);
        return _response;
    }


    bool tryRead(ref T lhs, Duration timeout = 0.usecs) shared
    {
        if(_isNull) return false;
        immutable bool check = (cast()_nofity).wait(timeout);
        if(check) {
            assert(!_isNull);
            lhs = _response;
        }
        return check;
    }


    bool tryRead(scope void delegate(shared(T)) dg, Duration timeout = 0.usecs) shared
    {
        if(_isNull) return false;
        immutable bool check = (cast()_nofity).wait(timeout);
        if(check) {
            assert(!_isNull);
            dg(_response);
            assert(!_isNull);
        }
        return check;
    }


  private:
    T _response;
    Event _nofity;
    bool _isNull;
}

unittest
{
    shared msg = NotifiedLazy!int.make();
    scope(exit) NotifiedLazy!int.dispose(cast(NotifiedLazy!int*)msg);

    assert(msg._isNull == true);

    msg.write(1);
    assert(msg._response == 1);
    assert(msg._isNull == false);
    msg.write(2);
    assert(msg._response == 1);
    assert(msg._isNull == false);
    assert(msg.read == 1);
}

unittest
{
    import core.thread;

    shared msg1 = NotifiedLazy!int.make(),
           msg2 = NotifiedLazy!int.make();
    scope(exit) {
        NotifiedLazy!int.dispose(cast(NotifiedLazy!int*)msg1);
        NotifiedLazy!int.dispose(cast(NotifiedLazy!int*)msg2);
    }

    int dst;
    assert(!msg1.tryRead(dst));
    assert(!msg1.tryRead((_){}));

    auto thread = new Thread((){
        assert(msg2.read == 2);
        assert(msg1.read == 1);
    }).start();
    scope(exit) thread.join();

    msg1.write(1);
    msg2.write(2);

    assert(msg1.tryRead(dst));
    assert(dst == 1);

    bool exec = false;
    assert(msg1.tryRead((x){ assert(x == 1); exec = true; }));
    assert(exec);
}


align(64) shared struct SpinLock
{
    import core.atomic;

    void lock() pure nothrow @safe @nogc
    {
        while(!cas(&_flag, cast(size_t)0, cast(size_t)1)) {
            core.atomic.pause();
        }
    }

    void unlock() pure nothrow @safe @nogc
    {
        atomicStore!(MemoryOrder.rel)(_flag, cast(size_t)0);
    }

private:
    size_t _flag;
}


struct Shared(T)
if(is(T : Object))
{
    this(shared(T) obj)
    {
        cast()this.obj = cast()obj;
    }

    this(ref return scope SharedRef rhs)
    {
        _obj = rhs._obj;
    }

    alias obj this;

    shared(T) obj;
}

unittest
{
    static synchronized class C { void foo() {} }
    // Shared!C c = new C);

}