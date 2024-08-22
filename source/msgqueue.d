module msgqueue;

import core.time;
import core.lifetime;

import std.typecons;
import std.traits;

import lock_free.rwqueue;
import std.experimental.allocator.mallocator;
import std.experimental.allocator;

import utils;
import multithread;


align(1) struct LWFp(alias fn)
{
    auto opCall(T...)(auto ref T args) const
    {
        return fn(forward!args);
    }
}

auto lwfp(alias fn)()
{
    static auto impl(T...)(auto ref T args)
    {
        return fn(forward!args);
    }

    LWFp!impl dst;
    return dst;
}

unittest
{
    int cnt;
    auto fp = lwfp!((ref int cnt, int a){ cnt += a; });
    fp(cnt, 1);
    fp(cnt, 2);
    assert(cnt == 3);
    assert(typeof(fp).sizeof == 1);
}


enum TaskKind
{
    RUN, READY, TERMINATE
}


struct TaskImpl(PtrType = void*, TaskType = bool function(PtrType, TaskKind) @nogc, size_t fieldSize = 64 - (void*).sizeof*2)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;
    alias alloc = Mallocator.instance;


    @disable this(this);
    @disable void opAssign(TaskImpl);


    enum size_t ON_FIELD_TAG = 1;


    ~this()
    {
        if(this._ptr is null) return;

        if(cast(size_t) this._ptr == ON_FIELD_TAG) {
            this._task(this._dummy.ptr, TaskKind.TERMINATE);
        } else {
            this._task(this._ptr, TaskKind.TERMINATE);
        }

        this._ptr = null;
        _task = null;
    }


    static
    TaskImpl make(Value, Pred, Callable)(Value v, Pred ready, Callable fn)
    if(is(PtrType == void*) || (isShareable!Value && isShareable!Pred && isShareable!Callable))
    {
        static struct Payload {
          align(1):
            Value v;
            Pred ready;
            Callable fn;
        }
        static assert(is(PtrType == void*) || isShareable!Payload);
        enum bool placedOnField = Payload.sizeof <= fieldSize;


        static bool taskImpl(PtrType ptr, TaskKind type) {
            auto payload = cast(Payload*)ptr;
            final switch(type) {
            case TaskKind.RUN:
                payload.fn(payload.v);
                return false;
            case TaskKind.READY:
                return payload.ready(payload.v);
            case TaskKind.TERMINATE:
                static if(placedOnField) {
                    Payload p = move(*payload);
                } else {
                    alloc.dispose(payload);
                }
                return false;
            }
        }


        static if(placedOnField) {
            TaskImpl dst;
            Payload* ptr = cast(Payload*)dst._dummy.ptr;
            move(v, ptr.v);
            move(ready, ptr.ready);
            move(fn, ptr.fn);
            dst._ptr = cast(PtrType)ON_FIELD_TAG;
            dst._task = &taskImpl;

            return dst;
        } else {
            // import std.meta;
            // pragma(msg, AliasSeq!(Value, Pred, Callable, file, line, Payload.sizeof, fieldSize));
            static void terminateImpl(PtrType ptr) {
                auto payload = cast(Payload*)ptr;
                alloc.dispose(payload);
            }

            Payload* ptr = alloc.make!Payload();
            move(v, ptr.v);
            move(ready, ptr.ready);
            move(fn, ptr.fn);

            return TaskImpl(cast(PtrType)ptr, &taskImpl);
        }
    }


    static
    TaskImpl* new_(Value, Pred, Callable)(Value v, Pred ready, Callable fn)
    if(is(PtrType == void*) || (isShareable!Value && isShareable!Pred && isShareable!Callable))
    {
        TaskImpl instance = TaskImpl.make(move(v), move(ready), move(fn));
        TaskImpl* ptr = alloc.make!TaskImpl();
        move(instance, *ptr);
        return ptr;
    }


    static
    void dispose(TaskImpl* ptr)
    {
        alloc.dispose(ptr);
    }


    bool isReady()
    {
        assert(_ptr !is null);

        if(cast(size_t)_ptr == ON_FIELD_TAG) {
            return this._task(_dummy.ptr, TaskKind.READY);
        } else {
            return this._task(this._ptr, TaskKind.READY);
        }
    }


    void run()
    {
        assert(_ptr !is null);
        if(cast(size_t)_ptr == ON_FIELD_TAG) {
            this._task(_dummy.ptr, TaskKind.RUN);
        } else {
            this._task(_ptr, TaskKind.RUN);
        }
    }


  private:
    PtrType _ptr;
    TaskType _task;

  static if(is(PtrType == shared(void)*))
  {
    shared(void)[fieldSize] _dummy;
  }
  else
  {
    void[fieldSize] _dummy;
  }
}

alias Task = TaskImpl!(void*);
alias SharedNoGCTask = TaskImpl!(shared(void)*, bool function(shared(void)*, TaskKind) @nogc);

unittest
{
    static assert(TaskImpl!(void*, bool function(void*, TaskKind), 64 - (void*).sizeof * 2).sizeof == 64);

    bool ready = false;
    bool done = false;
    Task task = Task.make(1, (int) => ready, (int){ done = true; });

    assert(!task.isReady());
    ready = true;
    assert(task.isReady());
    task.run();
    assert(done);

    static assert(!isShareable!Task);
    static assert(isShareable!SharedNoGCTask);
}


struct Disposer
{
    import core.thread;


    @disable this(this);
    @disable void opAssign(Disposer);


    static
    Disposer opCall()
    {
        Disposer inst;
        inst._list = new shared(LockQueue!(SharedNoGCTask))(1024);
        return inst;
    }


    ~this() shared
    {
        this.tryDisposeAll();
        if(&this !is Disposer.instance) {
            while(1) {
                SharedNoGCTask task;
                if(!_list.pop(task)) break;
                Disposer.instance._list.push(move(task));
            }
        }
    }


    void push(T)(T value) shared
    if(isShareable!T)
    {
        _list.push(SharedNoGCTask.make(move(value), lwfp!((ref _) => true), lwfp!((ref _){})));
    }


    void push(T, Pred)(T value, Pred ready) shared
    if(isShareable!T && isShareable!Pred && !isDelegate!Pred)
    {
        _list.push(SharedNoGCTask.make(move(value), move(ready), lwfp!((ref _){})));
    }


    void push(T, Pred, Callable)(T value, Pred ready, Callable finalize) shared
    if(isShareable!T && isShareable!Pred && isShareable!Callable)
    {
        _list.push(SharedNoGCTask.make(move(value), move(ready), move(finalize)));
    }


    bool tryDisposeFront() shared
    {
        SharedNoGCTask task;
        if(!_list.pop(task)) return false;

        if(task.isReady()) {
            task.run();
            return true;
        } else {
            _list.push(move(task));
            return false;
        }
    }


    size_t tryDisposeAll() shared
    {
        size_t cnt = 0;
        immutable len = _list.length;
        foreach(i; 0 .. len) {
            if(this.tryDisposeFront())
                ++cnt;
        }

        return cnt;
    }


    static
    shared(Disposer)* instance()
    {
        return &_instance;
    }


  private:
    shared(LockQueue!(SharedNoGCTask)) _list;
    shared static Disposer _instance;
}


shared static this()
{
    Disposer._instance._list = new shared(LockQueue!(SharedNoGCTask))(1024);
}


unittest
{
    static struct TestData
    {
        shared(int)* ptr;
        @disable this(this);
        ~this() @nogc { if(ptr) (*ptr) = (*ptr) + 1; }
    }

    shared(int)* p1 = new int;
    TestData data1 = TestData(p1);

    shared(Disposer) list = Disposer();
    list.push(move(data1));

    assert(*p1 == 0);
    assert(list.tryDisposeFront());
    assert(*p1 == 1);

    TestData data2 = TestData(p1);
    *p1 = 0;
    list.push(move(data2), function(ref TestData d) { return *(d.ptr) == 1; });
    assert(*p1 == 0);
    assert(!list.tryDisposeFront());
    assert(*p1 == 0);

    *p1 = 1;
    assert(*p1 == 1);
    assert(list.tryDisposeFront());
    assert(*p1 == 2);


    TestData data3 = TestData(p1);
    list.push(move(data3), function(ref TestData d) { return *(d.ptr) == 1; }, function(ref TestData d) { *(d.ptr) = 100; });
    assert(list.tryDisposeAll() == 0);
    *p1 = 1;
    assert(list.tryDisposeAll() == 1);
    assert(*p1 == 101);
}


struct SharedTaskList(Flag!"locked" locked = Yes.locked)
{
    import std.meta : allSatisfy;


    @disable this(this);
    @disable void opAssign(SharedTaskList);


    static
    SharedTaskList opCall(size_t size = 4096 / SharedNoGCTask.sizeof)
    {
        SharedTaskList inst;

        static if(locked)
            cast()inst._list = cast()new shared LockQueue!(SharedNoGCTask)(size);
        else
            cast()inst._list = new LockFreeSPSCQueue!(SharedNoGCTask)(size);

        return inst;
    }


    size_t length() shared const @nogc { return _list.length; }
    bool empty() shared const @nogc { return _list.empty; }


    void push(Callable, T...)(Callable func, T args) shared
    if(isShareable!Callable && allSatisfy!(isShareable, T))
    {
        static struct Packed { Callable func; T args; }
        static bool readyImpl(ref Packed) { return true; }
        static void runImpl(ref Packed impl) { impl.func(impl.args); }

        Packed value;
        move(func, value.func);
        static foreach(i, E; T)
            move(args[i], value.args[i]);

        _list.push(SharedNoGCTask.make(move(value), lwfp!readyImpl, lwfp!runImpl));
    }


    bool processFront() shared
    {
        SharedNoGCTask task;
        if(!_list.pop(task)) return false;

        task.run();
        return true;
    }


    size_t processAll() shared
    {
        size_t cnt = 0;
        while(1) {
            if(!this.processFront())
                return cnt;

            ++cnt;
        }

        return cnt;
    }

  private:
  static if(locked)
    shared(LockQueue!(SharedNoGCTask)) _list;
  else
    shared(LockFreeSPSCQueue!(SharedNoGCTask)) _list;
}

unittest
{
    shared(SharedTaskList!(Yes.locked)) list = SharedTaskList!(Yes.locked)();

    shared(int)* p1 = new int;
    list.push((shared(int)* a){ *a = *a + 1; }, p1);
    assert(*p1 == 0);
    assert(list.processAll() == 1);
    assert(*p1 == 1);

    shared(int)* p2 = new int;
    *p2 = 3;
    list.push((shared(int)* a, shared(int)* b) { *a = *b; }, p1, p2);
    assert(*p1 == 1);
    assert(*p2 == 3);
    assert(list.processAll() == 1);
    assert(*p1 == 3);
    assert(*p2 == 3);
}

unittest
{
    shared list = SharedTaskList!(No.locked)();

    shared(int)* p1 = new int;
    list.push((shared(int)* a){ *a = *a + 1; }, p1);
    assert(*p1 == 0);
    assert(list.processAll() == 1);
    assert(*p1 == 1);

    shared(int)* p2 = new int;
    *p2 = 3;
    list.push((shared(int)* a, shared(int)* b) { *a = *b; }, p1, p2);
    assert(*p1 == 1);
    assert(*p2 == 3);
    assert(list.processAll() == 1);
    assert(*p1 == 3);
    assert(*p2 == 3);
}
