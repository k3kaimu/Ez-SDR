module msgqueue;

import core.time;
import core.lifetime : move;

import std.typecons;
import std.traits;

import lock_free.rwqueue;
import std.experimental.allocator.mallocator;
import std.experimental.allocator;
import automem.vector;


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
    this(size_t initlen = 4096 / T.sizeof)
    {
        _data.length = initlen;
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

        move(cast()_data[_rpos], result);
        _rpos = (_rpos + 1) % _data.length;
        return true;
    }


    synchronized void push(T result)
    {
        if(_rpos == (_wpos + 1) % _data.length) {
            immutable oldlen = _data.length;
            _data.length = _data.length * 2;

            if(_wpos < _rpos) {
                foreach(i; 0 .. _wpos)
                    move(cast()_data[i], cast()_data[oldlen + i]);

                _wpos = oldlen + _wpos;
            }
        }

        move(result, cast()_data[_wpos]);
        _wpos = (_wpos + 1) % _data.length;
    }

  private:
    T[] _data;
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


struct TaskImpl(PtrType = void*, size_t fieldSize = 64 - (void*).sizeof*2)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;
    alias alloc = Mallocator.instance;


    @disable this(this);
    @disable void opAssign(TaskImpl);


    enum size_t ON_FIELD_TAG = 1;

    enum TaskType
    {
        RUN, READY, TERMINATE
    }


    ~this()
    {
        if(this._ptr is null) return;

        if(cast(size_t) this._ptr == ON_FIELD_TAG) {
            this._task(this._dummy.ptr, TaskType.TERMINATE);
        } else {
            this._task(this._ptr, TaskType.TERMINATE);
        }

        this._ptr = null;
        _task = null;
    }


    static
    TaskImpl make(Value, Pred, Callable, string file = __FILE__, size_t line = __LINE__)(Value v, Pred ready, Callable fn)
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


        static bool taskImpl(PtrType ptr, TaskType type) {
            auto payload = cast(Payload*)ptr;
            final switch(type) {
            case TaskType.RUN:
                payload.fn(payload.v);
                return false;
            case TaskType.READY:
                return payload.ready(payload.v);
            case TaskType.TERMINATE:
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
            return this._task(_dummy.ptr, TaskType.READY);
        } else {
            return this._task(this._ptr, TaskType.READY);
        }
    }


    void run()
    {
        assert(_ptr !is null);
        if(cast(size_t)_ptr == ON_FIELD_TAG) {
            this._task(_dummy.ptr, TaskType.RUN);
        } else {
            this._task(_ptr, TaskType.RUN);
        }
    }


  private:
    PtrType _ptr;
    bool function(PtrType, TaskType) _task;

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
alias SharedTask = TaskImpl!(shared(void)*);

unittest
{
    static assert(TaskImpl!(void*, 64 - (void*).sizeof * 2).sizeof == 64);

    bool ready = false;
    bool done = false;
    Task task = Task.make(1, (int) => ready, (int){ done = true; });

    assert(!task.isReady());
    ready = true;
    assert(task.isReady());
    task.run();
    assert(done);

    static assert(!isShareable!Task);
    static assert(isShareable!SharedTask);
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
        inst._list = new LockQueue!(SharedTask)(1024);
        return inst;
    }


    ~this() shared
    {
        this.tryDisposeAll();
        if(&this !is Disposer.instance) {
            while(1) {
                SharedTask task;
                if(!_list.pop(task)) break;
                Disposer.instance._list.push(move(task));
            }
        }
    }


    void push(T)(T value) shared
    if(isShareable!T)
    {
        _list.push(SharedTask.make(move(value), function(ref T v){ return true; }, function(ref T v){}));
    }


    void push(T, Pred)(T value, Pred ready) shared
    if(isShareable!T && isShareable!Pred && !isDelegate!Pred)
    {
        _list.push(SharedTask.make(move(value), move(ready), function(ref T v){}));
    }


    void push(T, Pred, Callable)(T value, Pred ready, Callable finalize) shared
    if(isShareable!T && isShareable!Pred && isShareable!Callable)
    {
        _list.push(SharedTask.make(move(value), move(ready), move(finalize)));
    }


    bool tryDisposeFront() shared
    {
        SharedTask task;
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
    shared(LockQueue!(SharedTask)) _list;
    shared static Disposer _instance;
}


shared static this()
{
    Disposer._instance._list = new LockQueue!(SharedTask)(1024);
}


unittest
{
    static struct TestData
    {
        shared(int)* ptr;
        @disable this(this);
        ~this(){ if(ptr) (*ptr) = (*ptr) + 1; }
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


struct SharedTaskList
{
    import std.meta : allSatisfy;


    @disable this(this);
    @disable void opAssign(SharedTaskList);


    static
    SharedTaskList opCall()
    {
        SharedTaskList inst;
        inst._list = new LockQueue!(SharedTask)(1024);
        return inst;
    }


    size_t length() shared const { return _list.length; }


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

        _list.push(SharedTask.make(value, &readyImpl, &runImpl));
    }


    bool processFront() shared
    {
        SharedTask task;
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
    shared(LockQueue!(SharedTask)) _list;
}

unittest
{
    shared(SharedTaskList) list = SharedTaskList();

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


final class RequestQueue(Req, Flag!"assumeUnique" assumeUnique = No.assumeUnique,  Allocator = Mallocator)
{
    import core.lifetime : move;

    static if(assumeUnique)
    {
        private {
            alias IOReq = Req;
        }
    }
    else
    {
        private {
            alias IOReq = shared(Req);
        }
    }

    static if(!is(typeof(Allocator.instance)))
    {
        this(Allocator alloc)
        {
            _alloc = alloc;
        }


        ref Allocator allocator() {
            return _alloc;
        }


        private Allocator _alloc;
    }
    else
    {
        static ref auto allocator() {
            return Allocator.instance;
        }
    }


    void pushRequest()(auto ref IOReq req) shared
    {
        IOReq* p = this.allocator.make!(IOReq)();
        move(req, *p);
        _reqList.push(cast(shared) p);
    }


    IOReq popRequest() shared
    {
        IOReq* p = cast(IOReq*)_reqList.pop();
        scope(exit) this.allocator.dispose(p);
        return move(*p);
    }


    bool emptyRequest() shared
    {
        return _reqList.empty;
    }


    Commander makeCommander() shared
    {
        return new Commander(this);
    }


    Executer makeExecuter() shared
    {
        return new Executer(this);
    }


    static final class Commander
    {
        this(shared RequestQueue queue)
        {
            _queue = queue;
        }


        void push(Req req)
        {
            _queue.pushRequest(req);
        }


        shared RequestQueue _queue;
    }


    static final class Executer
    {
        this(shared RequestQueue queue)
        {
            _queue = queue;
        }


        IOReq[] allRequestList()
        {
            return _reqList[];
        }


        void peekAllRequest()
        {
            while(! _queue.emptyRequest)
                _reqList ~= _queue.popRequest();
        }


        bool empty()
        {
            this.peekAllRequest();
            return _reqList.empty;
        }


        IOReq front()
        {
            this.peekAllRequest();
            return _reqList[0];
        }


        void popFront()
        {
            this.peekAllRequest();
            _reqList.popFront();
        }


      private:
        shared RequestQueue _queue;
        Vector!(IOReq, Allocator) _reqList;
    }



  private:
    RWQueue!(Req*) _reqList;
}


alias UniqueRequestQueue(Req, Allocator = Mallocator) = RequestQueue!(Req, Yes.assumeUnique, Allocator);



/**
Move Semantics Message Queue
*/
final class MsgQueue(Req, Res, Flag!"assumeUnique" assumeUnique = No.assumeUnique, Allocator = Mallocator)
{
    import core.lifetime : move;

    static if(assumeUnique)
    {
        private {
            alias IOReq = Req;
            alias IORes = Res;
            alias IOReqResPair = ReqResPair;
        }
    }
    else
    {
        private {
            alias IOReq = shared(Req);
            alias IORes = shared(Res);
            alias IOReqResPair = shared(ReqResPair);
        }
    }

    static if(!is(typeof(Allocator.instance)))
    {
        this(Allocator alloc)
        {
            _alloc = alloc;
        }


        ref Allocator allocator() {
            return _alloc;
        }


        private Allocator _alloc;
    }
    else
    {
        static ref auto allocator() {
            return Allocator.instance;
        }
    }


    void pushRequest()(auto ref IOReq req) shared
    {
        IOReq* p = this.allocator.make!(IOReq)();
        move(req, *p);
        _reqList.push(cast(shared) p);
    }


    IOReq popRequest() shared
    {
        IOReq* p = cast(IOReq*)_reqList.pop();
        scope(exit) this.allocator.dispose(p);
        return move(*p);
    }


    void pushResponse()(auto ref IOReq req, auto ref IORes res) shared
    {
        IOReqResPair* p = this.allocator.make!(IOReqResPair)(move(req), move(res));
        _resList.push(cast(shared) p);
    }


    IOReqResTuple popResponse() shared
    {
        IOReqResPair* p = cast(IOReqResPair*)_resList.pop();
        scope(exit) this.allocator.dispose(p);
        return IOReqResTuple(move(p.req), move(p.res));
    }


    bool emptyRequest() shared
    {
        return _reqList.empty;
    }


    bool emptyResponse() shared
    {
        return _resList.empty;
    }

  static if(assumeUnique)
  {
    Commander makeCommander() shared
    {
        return new Commander(this);
    }


    Executer makeExecuter() shared
    {
        return new Executer(this);
    }


    static final class Commander
    {
        this(shared MsgQueue queue)
        {
            _queue = queue;
        }


        IOReqResTuple[] allResponseList()
        {
            return _resList[];
        }


        void peekAllResponse()
        {
            while(! _queue.emptyResponse)
                _resList ~= _queue.popResponse();
        }


        bool emptyResponse()
        {
            this.peekAllResponse();
            return _resList.empty;
        }


        IOReqResTuple popResponse()
        {
            this.peekAllResponse();
            auto f = _resList[0];
            _resList.popFront();
            return f;
        }


        void pushRequest(Req req)
        {
            _queue.pushRequest(req);
        }


        shared MsgQueue _queue;
        Vector!(IOReqResTuple, Allocator) _resList;
    }


    static final class Executer
    {
        this(shared MsgQueue queue)
        {
            _queue = queue;
        }


        IOReq[] allRequestList()
        {
            return _reqList[];
        }


        void peekAllRequest()
        {
            while(! _queue.emptyRequest)
                _reqList ~= _queue.popRequest();
        }


        bool emptyRequest()
        {
            this.peekAllRequest();
            return _reqList.empty;
        }


        Req popRequest()
        {
            this.peekAllRequest();
            auto f = _reqList[0];
            _reqList.popFront();
            return f;
        }


        void pushResponse(Req req, Res res)
        {
            _queue.pushResponse(req, res);
        }


      private:
        shared MsgQueue _queue;
        Vector!(IOReq, Allocator) _reqList;
    }
  }


  private:
    RWQueue!(Req*) _reqList;
    RWQueue!(ReqResPair*) _resList;


    static struct ReqResPair
    {
        Req req;
        Res res;
    }


    alias IOReqResTuple = Tuple!(IOReq, "req", IORes, "res");
}


/**
Move Semantics Message Queue with Unique Request and Unique Response
*/
alias UniqueMsgQueue(Req, Res, Allocator = Mallocator) = MsgQueue!(Req, Res, Yes.assumeUnique, Allocator);

// unittest
// {
//     static struct S {
//         int a;
//         @disable this(this);        // non-copyable
//     }
//     static struct U {
//         int[] a;
//         @disable this(this);        // non-copyable
//     }

//     UniqueMsgQueue!(S, U) q;
// }



