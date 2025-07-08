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

    this()(inout(T) v) inout
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

auto localRef(T)(T value)
if(is(T == shared))
{
    return LocalRef!T(value);
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


/// 配列の一括コピー（buffer1[] = buffer2[];）が安全に使える型かどうかをチェック
enum bool isMemcopyable(T) = __traits(isPOD, T);

unittest
{
    import std.complex;
    
    // プリミティブ型
    static assert(isMemcopyable!int);
    static assert(isMemcopyable!float);
    static assert(isMemcopyable!double);
    static assert(isMemcopyable!char);
    
    // Complex型
    static assert(isMemcopyable!(Complex!double));
    
    // 構造体
    struct Point { int x, y; }
    static assert(isMemcopyable!Point);
    
    // ポインタ
    static assert(isMemcopyable!(int*));
    
    // 静的配列
    static assert(isMemcopyable!(int[10]));
    
    // デストラクタを持つ構造体
    struct WithDestructor { 
        int x; 
        ~this() {} 
    }
    static assert(!isMemcopyable!WithDestructor);
    
    // postblitを持つ構造体
    struct WithPostblit {
        int x;
        this(this) {}
    }
    static assert(!isMemcopyable!WithPostblit);
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

    this(size_t minimumSize = 4096 / T.sizeof)
    {
        import std.math : nextPow2;

        if(minimumSize == 0)
            minimumSize = 1;

        // minimumSizeは2のべき乗でなければならない
        // 2のべき乗ではないなら，最も近い2のべき乗に切り上げる
        size_t size = (minimumSize & (minimumSize - 1)) == 0 ? minimumSize : nextPow2(minimumSize);
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


  static if(isMemcopyable!T)
  {
    /// 複数のアイテムを一度にキューに追加する
    /// 返り値: 実際に追加できたアイテムの数
    size_t push(scope T[] items) shared
    {
        if(items.length == 0) return 0;

        immutable wpos = _wpos.atomicLoad!(MemoryOrder.raw);
        immutable size = _data.length;

        // 利用可能なスペースを確認
        immutable rpos_cached = _rpos.atomicLoad!(MemoryOrder.acq);
        immutable available_space = size - (wpos - rpos_cached);
        
        if(available_space == 0) {
            return 0;
        }

        // 実際に書き込める要素数を決定
        immutable items_to_write = available_space < items.length ? available_space : items.length;
        
        

        // 以下のforeachのように各アイテムを順番に書き込みするが，これは効率が悪いのでリングバッファーの末尾までと，先頭からの二つに書き込みを分ける
        // foreach(i; 0 .. items_to_write) {
        //     move(items[i], cast()_data[(wpos + i) & (size - 1)]);
        // }
        immutable wpos_index = wpos & (size - 1);   // 書き込み開始位置
        if(wpos_index < _data.length && wpos_index + items_to_write <= _data.length) {
            // バッファーに直接書き込み
            cast()_data[wpos_index .. wpos_index + items_to_write] = items[0 .. items_to_write];
        } else {
            // バッファーの末尾まで書き込み，残りは先頭から書き込み
            immutable end_space = _data.length - wpos_index;
            cast()_data[wpos_index .. $] = items[0 .. end_space];
            cast()_data[0 .. (items_to_write - end_space)] = items[end_space .. items_to_write];
        }

        // 書き込み位置を更新
        _wpos.atomicStore!(MemoryOrder.rel)(wpos + items_to_write);
        return items_to_write;
    }


    /// 複数のアイテムを一度にキューから取得する
    /// 返り値: 実際に取得できたアイテムの数
    size_t pop(scope T[] items) shared
    {
        if(items.length == 0) return 0;

        immutable rpos = _rpos.atomicLoad!(MemoryOrder.raw);
        immutable size = _data.length;

        // 利用可能なデータを確認
        immutable wpos_cached = _wpos.atomicLoad!(MemoryOrder.acq);
        immutable available_items = wpos_cached - rpos;

        if(available_items == 0) {
            return 0;
        }

        // 実際に読み込める要素数を決定
        immutable items_to_read = available_items < items.length ? available_items : items.length;

        // 各アイテムを順番に読み込み
        foreach(i; 0 .. items_to_read) {
            move(cast()_data[(rpos + i) & (size - 1)], items[i]);
        }

        // 読み込み位置を更新
        _rpos.atomicStore!(MemoryOrder.rel)(rpos + items_to_read);
        return items_to_read;
    }

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


unittest
{
    // 複数アイテムのpush/popテスト
    shared(LockFreeSPSCQueue!size_t) queue = new LockFreeSPSCQueue!size_t(1024);
    
    // 空のキューから読み込みテスト
    size_t[] readBuffer = new size_t[10];
    assert(queue.pop(readBuffer) == 0);
    
    // 複数アイテム書き込みテスト
    size_t[] writeData = [1, 2, 3, 4, 5];
    assert(queue.push(writeData) == 5);
    assert(queue.length == 5);
    
    // 部分読み込みテスト
    size_t[] partialRead = new size_t[3];
    assert(queue.pop(partialRead) == 3);
    assert(partialRead == [1, 2, 3]);
    assert(queue.length == 2);
    
    // 残りを読み込み
    size_t[] remainingRead = new size_t[10];
    assert(queue.pop(remainingRead) == 2);
    assert(remainingRead[0 .. 2] == [4, 5]);
    assert(queue.length == 0);
    
    // 大量データのテスト
    size_t[] largeWrite = new size_t[1000];
    foreach(i; 0 .. 1000) largeWrite[i] = i;
    assert(queue.push(largeWrite) == 1000);
    
    size_t[] largeRead = new size_t[1000];
    assert(queue.pop(largeRead) == 1000);
    foreach(i; 0 .. 1000) assert(largeRead[i] == i);
    
    // キューが満杯の場合のテスト
    size_t[] oversizeWrite = new size_t[2000];
    foreach(i; 0 .. 2000) oversizeWrite[i] = i + 1000;
    assert(queue.push(oversizeWrite) == 1024); // キューサイズまでしか書き込めない
    
    // 空配列のテスト
    size_t[] emptyArray;
    assert(queue.push(emptyArray) == 0);
    assert(queue.pop(emptyArray) == 0);
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
